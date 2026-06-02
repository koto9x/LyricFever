//
//  PlexampPlayer.swift
//  Lyric Fever
//
//  Plexamp player adapter.
//
//  Plexamp exposes a local Plex Media Player HTTP control API on 127.0.0.1:32500.
//  We read playback state (playing/paused, position, ratingKey) from
//  /player/timeline/poll, and read track metadata (artist/title/album) from the
//  on-disk PlayQueue.json that Plexamp writes alongside its other state files.
//  This avoids needing a Plex token entirely.
//

import AppKit
import Foundation

// MARK: - Polled state structs

struct PlexampTimelineSnapshot {
    let state: String           // "playing" | "paused" | "stopped"
    let timeMs: Int             // current position in ms
    let durationMs: Int         // total duration in ms
    let ratingKey: String?      // /library/metadata/<ratingKey>
    let volume: Int?            // 0–100
    let machineIdentifier: String?  // Plexamp's own machine ID (for control commands)
}

struct PlexampMetadata {
    let ratingKey: String
    let title: String?
    let artist: String?
    let album: String?
}

// MARK: - PlexampPlayer

class PlexampPlayer: Player {

    // Plexamp's local control API
    private static let playerAPI = URL(string: "http://127.0.0.1:32500")!
    // Caller-side identifier for the Plex control protocol (arbitrary, just needs to be stable).
    private static let clientIdentifier = "studio.9x.lyric-fever"
    private static let pollInterval: TimeInterval = 1.0

    private(set) var timeline: PlexampTimelineSnapshot?
    private(set) var metadata: PlexampMetadata?
    private var lastPollDate: Date?
    private var commandID = 0
    private var pollTask: Task<Void, Never>?

    /// Gate: polling only runs when the LyricFever UI is visible.
    /// ViewModel sets this closure in `initPlexampObservation()`.
    /// Returns `false` by default (safe) until ViewModel wires it up.
    var shouldPoll: () -> Bool = { false }

    /// "What has the callback been told about so far?" — separate from `timeline`/`metadata`
    /// so callbacks fire as soon as they're hooked, even if polling discovered the state
    /// before the ViewModel had a chance to subscribe.
    private var lastReportedRatingKey: String?
    private var lastReportedPlaying: Bool?

    /// Called from the polling task whenever the active ratingKey changes
    /// (i.e. the user switched to a different track in Plexamp). Owner is
    /// responsible for hopping to MainActor before touching SwiftUI state.
    var onTrackChange: ((_ ratingKey: String?) -> Void)?

    /// Called from the polling task whenever the play/pause state changes.
    /// Independent of `onTrackChange` so menubar/UI can react to pauses
    /// without re-fetching lyrics.
    var onPlaybackStateChange: ((_ isPlaying: Bool) -> Void)?

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    init() {
        print("PlexampPlayer: init, starting polling task")
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: Player protocol — track details

    var albumName: String? { metadata?.album }
    var artistName: String? { metadata?.artist }
    var trackName: String? { metadata?.title }

    // MARK: Player protocol — timing

    @MainActor
    var currentTime: TimeInterval? {
        guard let t = timeline else { return nil }
        var ms = Double(t.timeMs)
        // If playing, project forward by elapsed wall-clock since the last poll
        // so currentTime advances smoothly between poll intervals.
        if t.state == "playing", let lastPoll = lastPollDate {
            ms += Date().timeIntervalSince(lastPoll) * 1000
        }
        return ms
    }

    var duration: Int? {
        timeline?.durationMs
    }

    // MARK: Player protocol — player state

    var isAuthorized: Bool {
        // Plexamp's local API has no auth requirement on the loopback interface.
        // "Authorized" here means: is the control surface reachable?
        isRunning
    }

    var isPlaying: Bool {
        timeline?.state == "playing"
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "tv.plex.plexamp" }
    }

    var volume: Int {
        timeline?.volume ?? 0
    }

    // MARK: Player protocol — controls

    func decreaseVolume() {
        let v = max(0, volume - 5)
        setVolume(to: Double(v))
    }

    func increaseVolume() {
        let v = min(100, volume + 5)
        setVolume(to: Double(v))
    }

    func setVolume(to newVolume: Double) {
        Task { await sendPlayerCommand("playback/setParameters", query: ["volume": "\(Int(newVolume))"]) }
    }

    func togglePlayback() {
        Task {
            await sendPlayerCommand("playback/playPause")
            // Force an immediate state poll so the UI reflects the new
            // play/pause state even if the menubar window just closed.
            await pollOnce()
        }
    }

    func rewind() {
        Task {
            await sendPlayerCommand("playback/skipPrevious")
            await pollOnce()
        }
    }

    func forward() {
        Task {
            await sendPlayerCommand("playback/skipNext")
            await pollOnce()
        }
    }

    func seek(toMillis millis: Int) {
        // Plex's seekTo offset is in milliseconds.
        Task {
            await sendPlayerCommand("playback/seekTo", query: ["offset": "\(max(0, millis))"])
            await pollOnce()
        }
        // Optimistically nudge our cached timeline so the highlight jumps
        // immediately instead of waiting for the next 1s poll.
        if var t = timeline {
            t = PlexampTimelineSnapshot(state: t.state, timeMs: millis, durationMs: t.durationMs, ratingKey: t.ratingKey, volume: t.volume, machineIdentifier: t.machineIdentifier)
            timeline = t
            lastPollDate = Date()
        }
    }

    // MARK: Player protocol — artwork

    @MainActor
    var artworkImage: NSImage? {
        get async {
            // Without a Plex token we can't pull the artwork directly off the Plex server.
            // ViewModel falls back to MusicBrainz when this returns nil, which is fine.
            return nil
        }
    }

    // MARK: Player protocol — menubar / activation

    func activate() {
        NSWorkspace.shared.launchApplication("Plexamp")
    }

    var currentHoverItem: MenubarButtonHighlight { .none }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.shouldPoll() == true {
                    await self?.pollOnce()
                    try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                } else {
                    // UI hidden: sleep longer between checks, don't hit Plexamp's HTTP API.
                    try? await Task.sleep(nanoseconds: UInt64(5.0 * 1_000_000_000))
                }
            }
        }
    }

    private func pollOnce() async {
        // Skip cheaply when Plexamp isn't even running
        guard isRunning else {
            if timeline != nil { print("PlexampPlayer: Plexamp not running, clearing timeline") }
            timeline = nil
            return
        }
        print("PlexampPlayer: pollOnce — Plexamp running, fetching timeline")
        commandID += 1
        var components = URLComponents(url: Self.playerAPI.appendingPathComponent("player/timeline/poll"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "wait", value: "0"),
            URLQueryItem(name: "commandID", value: "\(commandID)"),
        ]
        guard let url = components.url else { return }
        var req = URLRequest(url: url)
        req.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        // X-Plex-Target-Client-Identifier deliberately omitted: we are a read-only polling
        // client, not a Plex controller. Including it caused Plexamp to treat LyricFever as
        // a competing controller and hang its play button on track starts.

        do {
            let (data, _) = try await urlSession.data(for: req)
            guard let parsed = Self.parseTimelineXML(data: data) else {
                print("PlexampPlayer: parseTimelineXML returned nil (no music timeline in response)")
                return
            }
            print("PlexampPlayer: parsed timeline state=\(parsed.state) ratingKey=\(parsed.ratingKey ?? "nil")")
            timeline = parsed
            print("PlexampPlayer: assigned timeline; lastReportedRatingKey=\(lastReportedRatingKey ?? "nil")")
            lastPollDate = Date()
            if let key = parsed.ratingKey {
                print("PlexampPlayer: have key=\(key), metadata?.ratingKey=\(metadata?.ratingKey ?? "nil")")
                if metadata?.ratingKey != key {
                    print("PlexampPlayer: about to read PlayQueue metadata for key=\(key)")
                    metadata = Self.readPlayQueueMetadata(forRatingKey: key)
                    print("PlexampPlayer: read PlayQueue metadata result: title=\(metadata?.title ?? "nil") artist=\(metadata?.artist ?? "nil")")
                }
                print("PlexampPlayer: checking lastReportedRatingKey \(lastReportedRatingKey ?? "nil") vs key \(key)")
                if lastReportedRatingKey != key {
                    if let cb = onTrackChange {
                        print("PlexampPlayer: firing onTrackChange(\(key))")
                        cb(key)
                        lastReportedRatingKey = key
                    } else {
                        print("PlexampPlayer: onTrackChange callback is nil — ViewModel hasn't subscribed yet")
                    }
                }
            } else {
                print("PlexampPlayer: parsed.ratingKey was nil despite parser said \(parsed.ratingKey ?? "nil")")
            }
            let nowPlaying = parsed.state == "playing"
            if lastReportedPlaying != nowPlaying, let cb = onPlaybackStateChange {
                cb(nowPlaying)
                lastReportedPlaying = nowPlaying
            }
        } catch {
            // Network errors are silent — Plexamp may have just quit or the poll may have raced.
        }
    }

    // MARK: Control

    private func sendPlayerCommand(_ path: String, query: [String: String] = [:]) async {
        commandID += 1
        var components = URLComponents(url: Self.playerAPI.appendingPathComponent("player/\(path)"), resolvingAgainstBaseURL: false)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "commandID", value: "\(commandID)"))
        components.queryItems = items
        guard let url = components.url else { return }
        var req = URLRequest(url: url)
        req.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Target-Client-Identifier")
        _ = try? await urlSession.data(for: req)
    }

    // MARK: Parsers

    private static func parseTimelineXML(data: Data) -> PlexampTimelineSnapshot? {
        // Minimal XML parse — pull the first Timeline whose type="music" or whose state != "stopped".
        let parser = TimelineParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.result
    }

    private static func readPlayQueueMetadata(forRatingKey key: String) -> PlexampMetadata? {
        // Sandboxed apps: NSHomeDirectory() returns the container's fake home, not
        // the real user home where Plexamp writes PlayQueue.json. getpwuid(getuid())
        // gives us the real $HOME — must pair with a home-relative-path entitlement
        // for the read to actually be permitted.
        guard let pwd = getpwuid(getuid()), let dir = pwd.pointee.pw_dir else { return nil }
        let realHome = String(cString: dir)
        let url = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Application Support/Plexamp/PlayQueue.json")
        guard let data = try? Data(contentsOf: url) else {
            print("PlexampPlayer: failed to read PlayQueue.json at \(url.path) — likely a sandbox entitlement issue")
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let container = payload["MediaContainer"] as? [String: Any],
              let items = container["Metadata"] as? [[String: Any]] else { return nil }
        for item in items {
            // ratingKey can be a String or an Int depending on the source — accept both.
            let itemKey: String? = {
                if let s = item["ratingKey"] as? String { return s }
                if let n = item["ratingKey"] as? NSNumber { return n.stringValue }
                return nil
            }()
            guard itemKey == key else { continue }
            return PlexampMetadata(
                ratingKey: key,
                title: item["title"] as? String,
                artist: item["grandparentTitle"] as? String,
                album: item["parentTitle"] as? String
            )
        }
        return nil
    }
}

// MARK: - XML parser

private final class TimelineParser: NSObject, XMLParserDelegate {
    var result: PlexampTimelineSnapshot?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
        guard elementName == "Timeline" else { return }
        let isMusic = (attrs["type"] ?? "") == "music" || (attrs["itemType"] ?? "") == "music"
        // Prefer the music timeline; ignore video/photo lines.
        guard isMusic else { return }
        let state = attrs["state"] ?? "stopped"
        let timeMs = Int(attrs["time"] ?? "0") ?? 0
        let durationMs = Int(attrs["duration"] ?? "0") ?? 0
        let ratingKey = attrs["ratingKey"]
        let volume = (attrs["volume"]).flatMap(Int.init)
        let machineId = attrs["machineIdentifier"]
        result = PlexampTimelineSnapshot(
            state: state,
            timeMs: timeMs,
            durationMs: durationMs,
            ratingKey: ratingKey,
            volume: volume,
            machineIdentifier: machineId
        )
    }
}

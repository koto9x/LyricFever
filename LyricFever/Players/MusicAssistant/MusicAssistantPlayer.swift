//
//  MusicAssistantPlayer.swift
//  Lyric Fever
//
//  Music Assistant player adapter.
//
//  Music Assistant (kaiosmini, ma.9x.studio) aggregates Plex/Apple Music/YouTube
//  Music/NTS Radio into one playback hub, so instead of tracking each source
//  app separately (the old Plexamp/Apple Music/Spotify "smart routing" dance,
//  and the races that came with it) LyricFever watches MA's queues directly
//  over its push WebSocket. Whichever queue is actively playing becomes the
//  current track. Position updates ride the dedicated `queue_time_updated`
//  event (sub-second, no polling), and `queue_updated` carries full track
//  metadata changes.
//
//  MA's `queue_item_id` is a stable per-play identifier (unlike MediaRemote's
//  persistentID, which is what caused the WDA→LEMONADE race and the stuck
//  currentlyPlaying bugs on the Apple Music path).
//

import AppKit
import Foundation

// MARK: - Snapshot types

struct MAQueueSnapshot {
    let queueId: String
    let state: String              // "idle" | "playing" | "paused"
    let title: String?
    let artist: String?
    let album: String?
    let durationMs: Int?
    let elapsedMs: Double?
    /// LOCAL unix seconds at which `elapsedMs` was received. Anchoring the
    /// playback-position projection to our own clock (instead of the server's
    /// `elapsed_time_last_updated`) keeps lyric sync immune to clock skew
    /// between the MA host and this Mac.
    let elapsedLastUpdated: Double?
    let queueItemId: String?
    let imageURL: String?
}

// NOTE: sibling-track lyric prewarm (like preloadPlexampQueueLyrics) is not
// implemented yet. `player_queues/all`'s `items` field is just a count, not
// the actual upcoming tracks — that needs a separate `player_queues/items`
// call per queue, which is a reasonable fast-follow but out of scope here.

// MARK: - MusicAssistantPlayer

class MusicAssistantPlayer: NSObject, Player {

    private let hostProvider: () -> String
    private let tokenProvider: () -> String?

    private var urlSession: URLSession!
    private var wsTask: URLSessionWebSocketTask?
    private var messageID = 0
    private var authenticated = false
    private var reconnectTask: Task<Void, Never>?

    private(set) var queues: [String: MAQueueSnapshot] = [:]
    /// Whichever queue is currently playing. Nil when nothing's playing
    /// anywhere in MA. Sticky across momentary "idle" blips on the previously
    /// active queue so a brief buffering gap doesn't bounce us to a different
    /// idle queue.
    private(set) var activeQueueId: String?

    /// Gate: the socket only connects/stays connected when this returns true.
    /// ViewModel wires this to `useMusicAssistant` + LyricFever UI visibility,
    /// same shape as PlexampPlayer.shouldPoll.
    var shouldConnect: () -> Bool = { false }

    /// Fired when the active queue's `queue_item_id` changes (new track).
    var onTrackChange: ((_ queueItemId: String?) -> Void)?
    /// Fired when the active queue's playback state flips playing/paused.
    var onPlaybackStateChange: ((_ isPlaying: Bool) -> Void)?

    private var gateTask: Task<Void, Never>?

    init(host: @escaping () -> String, token: @escaping () -> String?) {
        self.hostProvider = host
        self.tokenProvider = token
        super.init()
        urlSession = URLSession(configuration: .default)
        startGateLoop()
    }

    deinit {
        wsTask?.cancel(with: .goingAway, reason: nil)
        reconnectTask?.cancel()
        gateTask?.cancel()
    }

    /// Self-contained lifecycle: checks `shouldConnect()` every couple of
    /// seconds and connects/disconnects the socket accordingly. Mirrors
    /// PlexampPlayer's `shouldPoll` gate, but since MA is push-based (not
    /// polled) this only needs to run rarely, not once per tick.
    private func startGateLoop() {
        gateTask?.cancel()
        gateTask = Task { [weak self] in
            while !Task.isCancelled {
                // All connection state is confined to the main actor; the
                // WS receive path hops there too (see receiveLoop).
                await MainActor.run { [weak self] in
                    self?.connectIfNeeded()
                    self?.disconnectIfNoLongerNeeded()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: Player protocol — track details

    private var activeSnapshot: MAQueueSnapshot? {
        activeQueueId.flatMap { queues[$0] }
    }

    var albumName: String? { activeSnapshot?.album }
    var artistName: String? { activeSnapshot?.artist }
    var trackName: String? { activeSnapshot?.title }

    // MARK: Player protocol — timing

    @MainActor
    var currentTime: TimeInterval? {
        guard let snap = activeSnapshot, var ms = snap.elapsedMs else { return nil }
        // Project forward by wall-clock time since we received the last
        // position update. MA broadcasts `queue_time_updated` sparsely (on
        // state changes/seeks, not per-second), so this projection is the
        // primary driver of lyric sync between events.
        if snap.state == "playing", let lastUpdated = snap.elapsedLastUpdated {
            ms += max(0, Date().timeIntervalSince1970 - lastUpdated) * 1000
        }
        return ms
    }

    var duration: Int? { activeSnapshot?.durationMs }

    // MARK: Player protocol — player state

    var isAuthorized: Bool { authenticated }

    var isPlaying: Bool { activeSnapshot?.state == "playing" }

    var isRunning: Bool { wsTask != nil && authenticated }

    var volume: Int { 0 } // MA volume is per-player (speaker), not per-queue; not surfaced here.

    // MARK: Player protocol — controls

    func decreaseVolume() {}
    func increaseVolume() {}
    func setVolume(to newVolume: Double) {}

    func togglePlayback() {
        guard let queueId = activeQueueId else { return }
        send(command: "player_queues/play_pause", args: ["queue_id": queueId])
    }

    func rewind() {
        guard let queueId = activeQueueId else { return }
        send(command: "player_queues/previous", args: ["queue_id": queueId])
    }

    func forward() {
        guard let queueId = activeQueueId else { return }
        send(command: "player_queues/next", args: ["queue_id": queueId])
    }

    func seek(toMillis millis: Int) {
        guard let queueId = activeQueueId else { return }
        // MA's seek command takes whole seconds, not ms.
        send(command: "player_queues/seek", args: ["queue_id": queueId, "position": max(0, millis / 1000)])
        // Optimistic local nudge so the highlight jumps immediately instead of
        // waiting for the next queue_time_updated tick.
        if let snap = queues[queueId] {
            queues[queueId] = MAQueueSnapshot(
                queueId: snap.queueId, state: snap.state, title: snap.title, artist: snap.artist,
                album: snap.album, durationMs: snap.durationMs, elapsedMs: Double(millis),
                elapsedLastUpdated: Date().timeIntervalSince1970, queueItemId: snap.queueItemId,
                imageURL: snap.imageURL
            )
        }
    }

    // MARK: Player protocol — artwork

    @MainActor
    var artworkImage: NSImage? {
        get async {
            guard let urlString = activeSnapshot?.imageURL, let url = URL(string: urlString) else { return nil }
            return await artwork(for: url)
        }
    }

    // MARK: Player protocol — menubar / activation

    func activate() {
        guard let url = URL(string: "https://ma.9x.studio") else { return }
        NSWorkspace.shared.open(url)
    }

    var currentHoverItem: MenubarButtonHighlight { .none }

    // MARK: - Connection lifecycle

    func connectIfNeeded() {
        guard shouldConnect() else { return }
        guard wsTask == nil else { return }
        guard let token = tokenProvider(), !token.isEmpty else { return }
        guard let url = URL(string: "ws://\(hostProvider())/ws") else { return }
        print("MusicAssistantPlayer: connecting to \(url.absoluteString)")
        let task = urlSession.webSocketTask(with: url)
        wsTask = task
        task.resume()
        receiveLoop()
        send(command: "auth", args: ["token": token])
    }

    func disconnectIfNoLongerNeeded() {
        guard !shouldConnect() else { return }
        disconnect()
    }

    private func disconnect() {
        reconnectTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        authenticated = false
        let hadActive = activeQueueId != nil
        queues = [:]
        activeQueueId = nil
        if hadActive {
            onPlaybackStateChange?(false)
        }
    }

    private func scheduleReconnect() {
        wsTask = nil
        authenticated = false
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.connectIfNeeded()
        }
    }

    private func nextMessageID() -> String {
        messageID += 1
        return "\(messageID)"
    }

    private func send(command: String, args: [String: Any] = [:]) {
        guard let task = wsTask else { return }
        var payload: [String: Any] = ["message_id": nextMessageID(), "command": command]
        if !args.isEmpty { payload["args"] = args }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                print("MusicAssistantPlayer: send(\(command)) failed: \(error)")
            }
        }
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
                case .failure(let error):
                    print("MusicAssistantPlayer: WS receive failed: \(error)")
                    DispatchQueue.main.async { self.scheduleReconnect() }
                case .success(let message):
                    if case .string(let text) = message {
                        // Serialize all state mutation onto the main queue —
                        // `queues`/`activeQueueId` are read by SwiftUI on main,
                        // and main is FIFO so message order is preserved.
                        DispatchQueue.main.async { self.handleIncoming(text) }
                    }
                    self.receiveLoop()
            }
        }
    }

    // MARK: - Incoming message handling

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let event = json["event"] as? String {
            handleEvent(event, objectId: json["object_id"] as? String, data: json["data"])
            return
        }
        if json["message_id"] != nil {
            if json["error_code"] != nil {
                print("MusicAssistantPlayer: command errored: \(json["details"] ?? "unknown")")
                if !authenticated {
                    // Auth was rejected (bad/expired token). Drop the socket and
                    // retry on the reconnect cadence instead of sitting on a
                    // connection that will refuse every command.
                    disconnect()
                    scheduleReconnect()
                }
                return
            }
            if !authenticated {
                // First successful result after connecting is the auth response.
                authenticated = true
                print("MusicAssistantPlayer: authenticated")
                send(command: "player_queues/all")
                return
            }
            if let result = json["result"] as? [[String: Any]] {
                // Seed from player_queues/all
                for dict in result {
                    if let snap = Self.parseQueueDict(dict) {
                        upsert(snapshot: snap)
                    }
                }
            }
            return
        }
        // Otherwise: ServerInfoMessage (sent once on connect) — nothing to do.
    }

    private func handleEvent(_ event: String, objectId: String?, data: Any?) {
        switch event {
            case "queue_updated", "queue_items_updated":
                guard let dict = data as? [String: Any], let snap = Self.parseQueueDict(dict) else { return }
                upsert(snapshot: snap)
            case "queue_time_updated":
                guard let queueId = objectId else { return }
                let elapsed: Double? = (data as? NSNumber)?.doubleValue
                guard let elapsed, let existing = queues[queueId] else { return }
                // Position-only update: no state or item change, so no
                // callbacks and no active-queue recompute needed.
                queues[queueId] = MAQueueSnapshot(
                    queueId: existing.queueId, state: existing.state, title: existing.title,
                    artist: existing.artist, album: existing.album, durationMs: existing.durationMs,
                    elapsedMs: elapsed * 1000, elapsedLastUpdated: Date().timeIntervalSince1970,
                    queueItemId: existing.queueItemId, imageURL: existing.imageURL
                )
            default:
                break
        }
    }

    private func upsert(snapshot: MAQueueSnapshot) {
        let previousActiveItemId = activeSnapshot?.queueItemId
        let previousActiveWasPlaying = activeSnapshot?.state == "playing"
        queues[snapshot.queueId] = snapshot
        recomputeActiveQueue()
        // Diff the ACTIVE queue's track/state across the whole update, so a
        // change fires exactly once whether it came from the active queue's
        // own snapshot or from the active queue switching to another one.
        let newActiveItemId = activeSnapshot?.queueItemId
        let newActiveIsPlaying = activeSnapshot?.state == "playing"
        if previousActiveItemId != newActiveItemId {
            onTrackChange?(newActiveItemId)
        }
        if previousActiveWasPlaying != newActiveIsPlaying {
            onPlaybackStateChange?(newActiveIsPlaying)
        }
    }

    /// Picks whichever queue is playing. Sticks with the current choice if it's
    /// still playing — and also while it's merely paused, so pausing MA doesn't
    /// instantly blank the lyrics — handing over only when a DIFFERENT queue
    /// starts actively playing.
    private func recomputeActiveQueue() {
        if let current = activeQueueId, queues[current] != nil {
            if queues[current]?.state == "playing" {
                return
            }
            if let playing = queues.values.first(where: { $0.state == "playing" }) {
                activeQueueId = playing.queueId
            }
            return
        }
        activeQueueId = queues.values.first { $0.state == "playing" }?.queueId
    }

    // MARK: - Parsing

    static func parseQueueDict(_ dict: [String: Any]) -> MAQueueSnapshot? {
        guard let queueId = dict["queue_id"] as? String else { return nil }
        let state = dict["state"] as? String ?? "idle"
        let elapsed = dict["elapsed_time"] as? Double

        let currentItem = dict["current_item"] as? [String: Any]
        let mediaItem = currentItem?["media_item"] as? [String: Any]
        // media_item.name is the clean track title; current_item.name is a
        // combined "Artist - Title" display string (e.g. "Hatchie - Part That
        // Bleeds") which would poison provider lookups keyed by track name.
        let title = (mediaItem?["name"] as? String) ?? (currentItem?["name"] as? String)
        let artists = mediaItem?["artists"] as? [[String: Any]]
        let artist = artists?.first?["name"] as? String
        let album = (mediaItem?["album"] as? [String: Any])?["name"] as? String
        let durationSeconds = (currentItem?["duration"] as? Double) ?? (mediaItem?["duration"] as? Double)
        let queueItemId = currentItem?["queue_item_id"] as? String
        let image = currentItem?["image"] as? [String: Any]
        let imagePath = image?["path"] as? String

        return MAQueueSnapshot(
            queueId: queueId,
            state: state,
            title: title,
            artist: artist,
            album: album,
            durationMs: durationSeconds.map { Int($0 * 1000) },
            elapsedMs: elapsed.map { $0 * 1000 },
            elapsedLastUpdated: Date().timeIntervalSince1970,
            queueItemId: queueItemId,
            imageURL: imagePath
        )
    }
}

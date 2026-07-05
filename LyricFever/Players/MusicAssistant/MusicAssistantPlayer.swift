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
    /// Position of `current_item` in the queue — used to fetch the upcoming
    /// window for lyric preloading.
    let currentIndex: Int?
    /// `media_item.uri` (e.g. "apple_music://track/123") — stable across
    /// replays, unlike `queue_item_id` which is per-enqueue. Used as the
    /// CoreData caching key so a song's lyrics survive across sessions.
    let mediaItemUri: String?
}

/// Metadata for an upcoming queue item, used to prewarm lyrics before the
/// track actually starts.
struct MAUpcomingTrack {
    let uri: String?
    let queueItemId: String?
    let title: String?
    let artist: String?
    let album: String?
    let durationSec: Double?

    var cacheKey: String? { uri ?? queueItemId }
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

    // Keepalive bookkeeping. MA pushes events sparsely (time updates only on
    // seeks/corrections), so a silently-dead socket — VPN rekey, sleep/wake,
    // Wi-Fi roam — looks identical to a quiet-but-healthy one: the pending
    // receive() never errors, the gate loop sees wsTask != nil, and lyrics
    // freeze on the last known track forever. A ping round-trip is the only
    // reliable liveness signal.
    private var lastPingSent: Date?
    private var lastPongReceived: Date = .distantPast

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
    /// Fired with the next few tracks of the active queue whenever they
    /// (re)load — ViewModel uses this to preload lyrics ahead of playback.
    var onUpcomingItems: ((_ upcoming: [MAUpcomingTrack]) -> Void)?

    /// message_id → request kind, so responses can be routed without relying
    /// on ordering heuristics.
    private var pendingRequests: [String: String] = [:]

    private var gateTask: Task<Void, Never>?

    init(host: @escaping () -> String, token: @escaping () -> String?) {
        self.hostProvider = host
        self.tokenProvider = token
        super.init()
        urlSession = URLSession(configuration: .default)
        // After sleep the socket is almost certainly dead — recycle it
        // immediately instead of waiting for the ping watchdog to notice.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        startGateLoop()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        wsTask?.cancel(with: .goingAway, reason: nil)
        reconnectTask?.cancel()
        gateTask?.cancel()
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wsTask != nil else { return }
            print("MusicAssistantPlayer: system woke — recycling socket")
            self.forceReconnect()
        }
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
                    self?.pingIfDue()
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
                imageURL: snap.imageURL, currentIndex: snap.currentIndex, mediaItemUri: snap.mediaItemUri
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
        lastPingSent = nil
        lastPongReceived = .distantPast
        task.resume()
        receiveLoop(task)
        send(command: "auth", args: ["token": token], kind: "auth")
    }

    /// Ping keepalive, driven by the 2s gate loop: ping every ~14s while a
    /// socket exists; if a pong hasn't come back within 10s the socket is
    /// presumed dead and recycled. Runs pre-auth too, so a connect attempt
    /// that black-holes (e.g. VPN tunnel mid-rekey) also gets recycled.
    private func pingIfDue() {
        guard let task = wsTask else { return }
        if let sent = lastPingSent, lastPongReceived < sent {
            if Date().timeIntervalSince(sent) > 10 {
                print("MusicAssistantPlayer: pong overdue — socket presumed dead, reconnecting")
                forceReconnect()
            }
            return
        }
        if lastPingSent == nil || Date().timeIntervalSince(lastPingSent!) >= 14 {
            lastPingSent = Date()
            task.sendPing { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.wsTask === task else { return }
                    if let error {
                        print("MusicAssistantPlayer: ping failed: \(error)")
                        self.forceReconnect()
                    } else {
                        self.lastPongReceived = Date()
                    }
                }
            }
        }
    }

    /// Tear down a presumed-dead socket; the gate loop re-establishes within
    /// 2s. Queue snapshots are deliberately kept so lyrics don't blank during
    /// the blip — the post-auth `player_queues/all` reseed replaces them
    /// wholesale (and drops any queues that vanished server-side).
    private func forceReconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        authenticated = false
        pendingRequests = [:]
        lastPingSent = nil
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
        pendingRequests = [:]
        lastPingSent = nil
        let hadActive = activeQueueId != nil
        queues = [:]
        activeQueueId = nil
        if hadActive {
            onPlaybackStateChange?(false)
        }
    }

    private func scheduleReconnect() {
        // Cancel before nil-ing — otherwise the old task lingers half-open
        // and its pending callbacks keep firing.
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        authenticated = false
        pendingRequests = [:]
        lastPingSent = nil
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.connectIfNeeded() }
        }
    }

    private func nextMessageID() -> String {
        messageID += 1
        return "\(messageID)"
    }

    private func send(command: String, args: [String: Any] = [:], kind: String? = nil) {
        guard let task = wsTask else { return }
        let messageID = nextMessageID()
        if let kind {
            pendingRequests[messageID] = kind
        }
        var payload: [String: Any] = ["message_id": messageID, "command": command]
        if !args.isEmpty { payload["args"] = args }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                print("MusicAssistantPlayer: send(\(command)) failed: \(error)")
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
                case .failure(let error):
                    print("MusicAssistantPlayer: WS receive failed: \(error)")
                    DispatchQueue.main.async {
                        // A cancelled socket's pending receive also lands here.
                        // Only react if this is still the LIVE socket — tearing
                        // down whatever replaced it would cause reconnect
                        // flapping (each cycle orphaning the next connection).
                        guard self.wsTask === task else { return }
                        self.scheduleReconnect()
                    }
                case .success(let message):
                    if case .string(let text) = message {
                        // Serialize all state mutation onto the main queue —
                        // `queues`/`activeQueueId` are read by SwiftUI on main,
                        // and main is FIFO so message order is preserved.
                        DispatchQueue.main.async {
                            guard self.wsTask === task else { return }
                            self.handleIncoming(text)
                        }
                    }
                    // Keep listening on THIS socket (not self.wsTask, which may
                    // have been replaced) — a stale loop ends at the guard above
                    // when its cancelled task's receive finally errors.
                    self.receiveLoop(task)
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
        if let messageID = json["message_id"] as? String {
            let kind = pendingRequests.removeValue(forKey: messageID)
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
            switch kind {
                case "auth":
                    authenticated = true
                    print("MusicAssistantPlayer: authenticated")
                    send(command: "player_queues/all", kind: "queues_all")
                case "queues_all":
                    if let result = json["result"] as? [[String: Any]] {
                        replaceQueues(with: result.compactMap(Self.parseQueueDict))
                        requestUpcomingItems()
                    }
                case "queue_items":
                    if let result = json["result"] as? [[String: Any]] {
                        let upcoming = result.compactMap(Self.parseUpcomingItem)
                        if !upcoming.isEmpty {
                            onUpcomingItems?(upcoming)
                        }
                    }
                default:
                    break // fire-and-forget command (play/pause/seek) responses
            }
            return
        }
        // Otherwise: ServerInfoMessage (sent once on connect) — nothing to do.
    }

    /// Ask MA for the next few tracks after the active queue's current index,
    /// so lyrics can be prewarmed before each track arrives.
    private func requestUpcomingItems() {
        guard let queueId = activeQueueId,
              let index = queues[queueId]?.currentIndex else { return }
        send(command: "player_queues/items",
             args: ["queue_id": queueId, "limit": 3, "offset": index + 1],
             kind: "queue_items")
    }

    private func handleEvent(_ event: String, objectId: String?, data: Any?) {
        switch event {
            case "queue_updated", "queue_items_updated":
                guard let dict = data as? [String: Any], let snap = Self.parseQueueDict(dict) else { return }
                upsert(snapshot: snap)
                if event == "queue_items_updated", snap.queueId == activeQueueId {
                    // Queue contents changed (tracks added/reordered) — refresh
                    // the preload window.
                    requestUpcomingItems()
                }
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
                    queueItemId: existing.queueItemId, imageURL: existing.imageURL,
                    currentIndex: existing.currentIndex, mediaItemUri: existing.mediaItemUri
                )
            default:
                break
        }
    }

    /// Wholesale reseed from `player_queues/all` — unlike upsert(), queues
    /// that no longer exist server-side (e.g. MA restarted while we were
    /// disconnected) are dropped, so a vanished queue can't sit in the dict
    /// claiming "playing" and projecting stale lyric positions forever.
    private func replaceQueues(with snapshots: [MAQueueSnapshot]) {
        let previousActiveItemId = activeSnapshot?.queueItemId
        let previousActiveWasPlaying = activeSnapshot?.state == "playing"
        queues = Dictionary(snapshots.map { ($0.queueId, $0) }, uniquingKeysWith: { _, new in new })
        if let current = activeQueueId, queues[current] == nil {
            activeQueueId = nil
        }
        recomputeActiveQueue()
        let newActiveItemId = activeSnapshot?.queueItemId
        let newActiveIsPlaying = activeSnapshot?.state == "playing"
        if previousActiveItemId != newActiveItemId {
            onTrackChange?(newActiveItemId)
        }
        if previousActiveWasPlaying != newActiveIsPlaying {
            onPlaybackStateChange?(newActiveIsPlaying)
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
            // New track underway — refresh the upcoming window so the next
            // few tracks' lyrics get prewarmed.
            requestUpcomingItems()
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

        let currentIndex = (dict["current_index"] as? NSNumber)?.intValue

        let currentItem = dict["current_item"] as? [String: Any]
        let mediaItem = currentItem?["media_item"] as? [String: Any]
        // media_item.name is the clean track title; current_item.name is a
        // combined "Artist - Title" display string (e.g. "Hatchie - Part That
        // Bleeds") which would poison provider lookups keyed by track name.
        let title = (mediaItem?["name"] as? String) ?? (currentItem?["name"] as? String)
        let mediaItemUri = mediaItem?["uri"] as? String
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
            imageURL: imagePath,
            currentIndex: currentIndex,
            mediaItemUri: mediaItemUri
        )
    }

    /// Parse one element of a `player_queues/items` result into the metadata
    /// needed for lyric prewarming.
    static func parseUpcomingItem(_ dict: [String: Any]) -> MAUpcomingTrack? {
        let mediaItem = dict["media_item"] as? [String: Any]
        let title = (mediaItem?["name"] as? String) ?? (dict["name"] as? String)
        guard title != nil else { return nil }
        let artists = mediaItem?["artists"] as? [[String: Any]]
        return MAUpcomingTrack(
            uri: mediaItem?["uri"] as? String,
            queueItemId: dict["queue_item_id"] as? String,
            title: title,
            artist: artists?.first?["name"] as? String,
            album: (mediaItem?["album"] as? [String: Any])?["name"] as? String,
            durationSec: (dict["duration"] as? NSNumber)?.doubleValue ?? (mediaItem?["duration"] as? NSNumber)?.doubleValue
        )
    }
}

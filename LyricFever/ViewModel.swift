//
//  viewModel.swift
//  SpotifyLyricsInMenubar
//
//  Created by Avi Wadhwa on 14/08/23.
//

import Foundation
#if os(macOS)
#endif
import CoreData
import AmplitudeSwift
import SwiftUI
import MediaPlayer
#if os(macOS)
import WebKit
import Translation
import KeyboardShortcuts
import MediaRemoteAdapter
#endif

@MainActor
@Observable class ViewModel {
    static let shared = ViewModel()
    
    // Apple Music Tahoe broken AppleScript workaround
    // bundleIdentifier param removed from MediaController.init in adapter b8ce5d1
    let musicController = MediaController()
//    var appleMusicUniqueIdentifier: String?

    var currentlyPlaying: String?
    
    var currentVolume: Int = 0
    var isStopped = false
    
    var artworkImage: NSImage?
    var currentArtworkURL: URL?

    var duration: Int = 0
    var currentTime = CurrentTimeWithStoredDate(currentTime: 0)
    
    var formattedCurrentTime: String {
        let baseTime = currentTime.currentTime
        let totalSeconds = Int(baseTime) / 1000
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: TimeInterval(totalSeconds)) ?? "0:00"
    }
    #if os(macOS)
    // MARK: - Plexamp UI visibility gate

    /// Set to `true` by FullscreenView.onAppear / onDisappear.
    @ObservationIgnored var fullscreenViewVisible: Bool = false
    /// Set to `true` by MenubarWindowView.onAppear / onDisappear.
    @ObservationIgnored var menubarViewVisible: Bool = false

    /// Polling is active when at least one LyricFever view is on screen.
    var isLyricFeverUIActive: Bool { fullscreenViewVisible || menubarViewVisible }

    /// Plexamp doesn't post DistributedNotificationCenter events the way Spotify and
    /// Apple Music do, so we drive song-change + play-state updates off PlexampPlayer's
    /// own polling callbacks. ViewModel keeps responsibility for the SwiftUI/CoreData
    /// state mutations.
    private func initPlexampObservation() {
        print("ViewModel: initPlexampObservation — usePlexamp via storage=\(userDefaultStorage.usePlexamp), via UserDefaults.standard=\(UserDefaults.standard.bool(forKey: "usePlexamp")), spotifyOrAppleMusic=\(userDefaultStorage.spotifyOrAppleMusic), currentPlayer=\(currentPlayer)")
        // Wire up the polling gate: PlexampPlayer only hits Plexamp's HTTP API
        // when LyricFever's UI (fullscreen or menubar window) is visible.
        plexampPlayer.shouldPoll = { [weak self] in
            self?.isLyricFeverUIActive ?? false
        }
        plexampPlayer.onTrackChange = { [weak self] key in
            print("ViewModel: PlexampPlayer.onTrackChange fired with key=\(key ?? "nil")")
            guard let self else { return }
            Task { @MainActor in
                guard self.currentPlayer == .plexamp else {
                    print("ViewModel: ignoring Plexamp track change — currentPlayer is \(self.currentPlayer)")
                    return
                }
                print("ViewModel: calling setCurrentProperties for Plexamp track change")
                self.setCurrentProperties()
            }
        }
        plexampPlayer.onPlaybackStateChange = { [weak self] isPlaying in
            print("ViewModel: PlexampPlayer.onPlaybackStateChange fired isPlaying=\(isPlaying)")
            guard let self else { return }
            Task { @MainActor in
                guard self.currentPlayer == .plexamp else { return }
                self.isPlaying = isPlaying
                if !isPlaying {
                    self.currentLyricsDriftFix?.cancel()
                }
            }
        }
    }

    /// Music Assistant pushes track-change + play-state updates over its own
    /// WebSocket (see MusicAssistantPlayer) — same shape as the Plexamp
    /// observation above, just driven by a socket instead of an HTTP poll.
    private func initMusicAssistantObservation() {
        musicAssistantPlayer.shouldConnect = { [weak self] in
            guard let self else { return false }
            return self.userDefaultStorage.useMusicAssistant && self.isLyricFeverUIActive
        }
        musicAssistantPlayer.onTrackChange = { [weak self] queueItemId in
            guard let self else { return }
            Task { @MainActor in
                guard self.currentPlayer == .musicAssistant else { return }
                self.setCurrentProperties()
            }
        }
        musicAssistantPlayer.onPlaybackStateChange = { [weak self] isPlaying in
            guard let self else { return }
            Task { @MainActor in
                guard self.currentPlayer == .musicAssistant else { return }
                self.isPlaying = isPlaying
                if !isPlaying {
                    self.currentLyricsDriftFix?.cancel()
                }
            }
        }
    }
    #endif

    private func initAppleMusicWorkaround() {
        musicController.onTrackInfoReceived = { data in
            print("Track info received")
            Task { @MainActor in
                guard let payload = data?.payload else { return }

                // ── Artwork (app-agnostic, title-guarded) ────────────────
                // Apply artwork from ANY MediaRemote source — Music, Plexamp,
                // Spotify, etc. This block must fire BEFORE the applicationName
                // and currentPlayer guards so Plexamp (and any other non-Music
                // source) can update the album art.
                // Title guard: a browser tab hosting the Music Assistant web
                // player keeps a stale Now Playing entry even when idle, and
                // its artwork was clobbering the actual player's art (Sophia
                // Stel cover on a Beatles track). Only accept artwork when the
                // payload's title plausibly matches what we're displaying.
                print("ViewModel: artwork from \(payload.applicationName ?? "?") — payload.artwork=\(payload.artwork == nil ? "nil" : "set"), artworkDataBase64.count=\(payload.artworkDataBase64?.count ?? 0)")
                if let artwork = payload.artwork {
                    let payloadTitle = payload.title ?? ""
                    let displayedTitle = self.currentlyPlayingName ?? ""
                    let titlesMatch = payloadTitle.isEmpty || displayedTitle.isEmpty
                        || displayedTitle.localizedCaseInsensitiveContains(payloadTitle)
                        || payloadTitle.localizedCaseInsensitiveContains(displayedTitle)
                    if titlesMatch {
                        self.artworkImage = artwork
                    } else {
                        print("ViewModel: skipping artwork from \(payload.applicationName ?? "?") — payload title \"\(payloadTitle)\" doesn't match displayed \"\(displayedTitle)\"")
                    }
                } else if self.currentlyPlaying == nil {
                    self.artworkImage = nil
                }

                // ── Apple-Music-only track-change detection ──────────────
                // Everything below only applies when the active player is
                // Apple Music and the notification is from Music.app.
                guard self.currentPlayer == .appleMusic else {
                    return
                }
                guard payload.applicationName == "Music" else {
                    return
                }
                // ── Source-of-truth track-change detection ──────────────
                // MediaRemoteAdapter delivers the freshest "what's actually
                // playing" snapshot — way more reliable than Music.app's
                // com.apple.Music.playerInfo notification, which can lag or
                // drop entirely on track transitions. If the title in the
                // payload doesn't match our cached currentlyPlayingName, kick
                // a re-detect through appleMusicNetworkFetch (which re-reads
                // Music.app via AppleScript and re-maps to Spotify ID).
                if let payloadTitle = payload.title,
                   !payloadTitle.isEmpty,
                   payloadTitle != self.currentlyPlayingName {
                    print("MediaRemote: track change detected (\(self.currentlyPlayingName ?? "nil") → \(payloadTitle)) — forcing chain refresh")
                    self.currentlyPlayingName = payloadTitle
                    self.currentlyPlayingArtist = payload.artist
                    self.currentAlbumName = payload.album
                    if let durationMicros = payload.durationMicros {
                        self.duration = Int(durationMicros / 1000)
                    }
                    // Refresh persistent ID directly off AppleScript — it
                    // catches up by the time MediaRemote fires (slightly
                    // after the playerInfo notification path).
                    let freshPID = self.appleMusicPlayer.persistentID
                    if let freshPID, freshPID != self.currentlyPlayingAppleMusicPersistentID {
                        self.currentlyPlayingAppleMusicPersistentID = freshPID
                    }
                    // Capture Apple Music catalog (Adam) IDs from MediaRemote payload.
                    // Nil for local files, audiobooks, or non-catalog tracks.
                    self.appleMusicPlayer.lastObservedCatalogID = payload.contentItemIdentifier
                    self.appleMusicPlayer.lastObservedAlbumCatalogID = payload.albumiTunesStoreAdamIdentifier
                    Task {
                        await self.appleMusicStarter()
                    }
                    // ── Auth prompts (once per install) ─────────────────────
                    // Only fire for Apple Music player — catalog ID is already
                    // captured above so we know this is a real streaming track.
                    if !self.hasOfferedAppleMusicAuth,
                       AppleMusicAuthManager.shared.status == .notDetermined {
                        self.hasOfferedAppleMusicAuth = true
                        self.showAppleMusicAuthSheet = true
                    }
                    if !AppleMusicAuthManager.shared.hasShownDeniedToast,
                       (AppleMusicAuthManager.shared.status == .denied ||
                        AppleMusicAuthManager.shared.status == .restricted) {
                        AppleMusicAuthManager.shared.markDeniedToastShown()
                        self.showAppleMusicDeniedToast = true
                    }
                    // ── Album-wide background lyric prefetch ─────────────────
                    if let albumID = self.appleMusicPlayer.lastObservedAlbumCatalogID,
                       !albumID.isEmpty,
                       self.currentPlayer == .appleMusic,
                       AppleMusicAuthManager.shared.isAuthorized {
                        Task.detached { [weak self] in
                            guard let self else { return }
                            await self.appleMusicPrefetcher.warmAlbum(albumID: albumID)
                            await self.appleMusicPrefetcher.warmQueueWindow(5, appleMusicPlayer: self.appleMusicPlayer)
                        }
                    }
                }
            }
        }
        musicController.startListening()
    }
    
    func formattedCurrentTime(for date: Date) -> String {
        let baseTime = currentTime.currentTime
        let delta = date.timeIntervalSince(currentTime.storedDate)
//        print("Formatted Current Time: delta is \(delta)")
        let totalSeconds = Int((baseTime + delta) / 1000)
//        print("total seconds should be \(totalSeconds)")
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: TimeInterval(totalSeconds)) ?? "0:00"
    }
    
    var formattedDuration: String {
        let totalSeconds = duration / 1000
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: TimeInterval(totalSeconds)) ?? "0:00"
    }
    
    #if os(macOS)
    var updaterService = UpdaterService()
    var appleMusicPlayer = AppleMusicPlayer()
    var spotifyPlayer = SpotifyPlayer()
    var plexampPlayer = PlexampPlayer()
    // Reads UserDefaults directly (rather than via UserDefaultStorage) since
    // these closures run off the main actor on a background gate loop and
    // don't need SwiftUI observation — just the current value.
    var musicAssistantPlayer = MusicAssistantPlayer(
        host: { UserDefaults.standard.string(forKey: "musicAssistantHost") ?? "100.114.244.6:8095" },
        token: { UserDefaults.standard.string(forKey: "musicAssistantToken").flatMap { $0.isEmpty ? nil : $0 } }
    )
    #else
    var currentTab = TabType.nowPlaying
    var spotifyPlayer = TVSpotifyPlayer()
    var hasWebApiOnboarded = false
    #endif

    var currentPlayerInstance: Player {
        #if os(macOS)
        switch currentPlayer {
            case .appleMusic:
                return appleMusicPlayer
            case .spotify:
                return spotifyPlayer
            case .plexamp:
                return plexampPlayer
            case .musicAssistant:
                return musicAssistantPlayer
        }
        #else
        return spotifyPlayer
        #endif
    }
    
    #if os(macOS)
    var translationSessionConfig: TranslationSession.Configuration?
    #endif
    var userDefaultStorage = UserDefaultStorage()
    
    #if os(macOS)
    // Karaoke Font
    var karaokeFont: NSFont
    
    // nil to deal with previously saved songs that don't have lang saved with them
    // or for LRCLIB
    var currentBackground: Color? = nil
    
    var animatedDisplay: Bool {
        get {
            displayKaraoke || fullscreen
        }
        set {
            
        }
    }
    
    var canDisplayLyrics: Bool {
        showLyrics && !lyricsIsEmptyPostLoad
    }

    var displayKaraoke: Bool {
        get {
            showLyrics && isPlaying && userDefaultStorage.karaoke && !karaokeModeHovering && (currentlyPlayingLyricsIndex != nil)
        }
        set {
            
        }
    }
    var displayFullscreen: Bool {
        get {
            fullscreen
        }
        set {
            if fullscreen {
                NSApp.windows.first {$0.identifier?.rawValue == "fullscreen"}?.makeKeyAndOrderFront(self)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                fullscreen = true
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
    var currentlyPlayingAppleMusicPersistentID: String? = nil
    #endif
    
    var currentlyPlayingName: String?
    var currentlyPlayingArtist: String?
    var currentAlbumName: String?
    // Stashes the most recent network-fetched lyrics result (including server-side
    // romanization + translation enrichment). Lets romanizeDidChange and the
    // translation flow short-circuit to server data when available, falling back
    // to Mecab / Apple Translation only when the server didn't provide them.
    var lastNetworkResult: NetworkFetchReturn? = nil

    // Smart-scroll state. The fullscreen lyric view auto-scrolls to the current
    // line; the moment the user touches their trackpad/scrollwheel, we set
    // `userScrolledOffSync = true`, freeze the auto-scroll, and the fullscreen
    // overlay surfaces a "snap to now" button that bumps `scrollResyncSignal`
    // and clears the flag — coordinator picks up the signal change and
    // animates back to the current line.
    var userScrolledOffSync: Bool = false
    var scrollResyncSignal: Int = 0
    var currentlyPlayingLyrics: [LyricLine] = []
    var currentlyPlayingLyricsIndex: Int?
    var isPlaying: Bool = false
    var romanizedLyrics: [String] = []
    var chineseConversionLyrics: [String] = []
    var translatedLyric: [String] = []
    var showLyrics = true
    var showAppleMusicAuthSheet: Bool = false
    var hasOfferedAppleMusicAuth: Bool = false
    var showAppleMusicDeniedToast: Bool = false
    #if os(macOS)
    var fullscreen = false
    var spotifyConnectDelay: Bool = false
    var airplayDelay: Bool = false
    #endif
    var isFetchingTranslation = false
    var translationExists: Bool { !translatedLyric.isEmpty}
    
    // CoreData container (for saved lyrics)
    let coreDataContainer: NSPersistentContainer
    
    // Logging / Analytics
    let amplitude = Amplitude(configuration: .init(apiKey: amplitudeKey))
    
    var isHearted = false
    
    // Async Tasks (Lyrics fetch, Apple Music -> Spotify ID fetch, Lyrics Updater)
    private var currentFetchTask: Task<[LyricLine], Error>?
    private var currentLyricsUpdaterTask: Task<Void,Error>?
    private var currentLyricsDriftFix: Task<Void,Error>?
    var isFetching = false
    private var currentAppleMusicFetchTask: Task<Void,Error>?
    
    // Songs are translated to user locale
    let systemLocale: Locale
    let systemLocaleString: String
    var translationSourceLanguage: Locale.Language?
//    var translationTargetLanguage: Locale.Language?
    var userLocaleLanguage: Locale.Language {
        if let translationTargetLanguage = userDefaultStorage.translationTargetLanguage {
            return translationTargetLanguage
        } else {
            return systemLocale.language
        }
    }
    var userLocaleLanguageString: String {
        if let translationTargetLanguage = userDefaultStorage.translationTargetLanguage, let translationTargetLanguageString = Locale.current.localizedString(forIdentifier: translationTargetLanguage.minimalIdentifier) {
            return translationTargetLanguageString
        } else {
            return systemLocaleString
        }
    }

    // Override menubar with an update message
    var mustUpdateUrgent: Bool = false

    // Delayed variable to hook onto for fullscreen (whether to display lyrics or not)
    // Prevents flickering that occurs when we directly bind to currentlyPlayingLyrics.isEmpty()
    var lyricsIsEmptyPostLoad: Bool = true
    
    #if os(macOS)
    // UI element used to hide if karaokeModeHoveringSetting is true
    var karaokeModeHovering: Bool = false
    
    #endif
    
    #if os(macOS)
    var currentPlayer: PlayerType {
        get {
            // Music Assistant, when enabled, takes priority over everything
            // below: it already aggregates Plex/Apple Music/YouTube Music/NTS
            // into one hub, so if it's actively playing something there's no
            // ambiguity about which app the user is actually listening to —
            // unlike the Plexamp/Apple Music/Spotify race this replaces.
            if self.userDefaultStorage.useMusicAssistant, musicAssistantPlayer.isPlaying {
                return .musicAssistant
            }
            // Routing priority for `usePlexamp = true`:
            //   1. Plexamp is actively playing → use Plexamp.
            //   2. Apple Music or Spotify is actively playing → use them
            //      (Plexamp may be running but paused in the background;
            //       the user is clearly listening to the other app).
            //   3. Plexamp is running (paused) → use Plexamp.
            //   4. Fall back to the spotifyOrAppleMusic toggle.
            //
            // This prevents the "Plexamp paused on a Night Tapes track in
            // the background while user listens to aespa on Apple Music"
            // case where stale Plexamp metadata leaks into the displayed
            // lyrics.
            if self.userDefaultStorage.usePlexamp {
                if plexampPlayer.isRunning && plexampPlayer.isPlaying {
                    return .plexamp
                }
                if appleMusicPlayer.isPlaying {
                    return .appleMusic
                }
                if spotifyPlayer.isPlaying {
                    return .spotify
                }
                if plexampPlayer.isRunning {
                    return .plexamp
                }
            }
            if self.userDefaultStorage.spotifyOrAppleMusic {
                return .appleMusic
            } else {
                return .spotify
            }
        } set {
            switch newValue {
                case .musicAssistant:
                    self.userDefaultStorage.useMusicAssistant = true
                case .plexamp:
                    self.userDefaultStorage.useMusicAssistant = false
                    self.userDefaultStorage.usePlexamp = true
                case .appleMusic:
                    self.userDefaultStorage.useMusicAssistant = false
                    self.userDefaultStorage.usePlexamp = false
                    self.userDefaultStorage.spotifyOrAppleMusic = true
                case .spotify:
                    self.userDefaultStorage.useMusicAssistant = false
                    self.userDefaultStorage.usePlexamp = false
                    self.userDefaultStorage.spotifyOrAppleMusic = false
            }
        }
    }
    #else
    @ObservationIgnored var currentPlayer: Player {
        return spotifyPlayer
    }
    #endif
    
    var currentDuration: Int? {
        currentPlayerInstance.duration
    }
    var isPlayerRunning: Bool {
        currentPlayerInstance.isRunning
    }
    
    var spotifyLyricProvider = SpotifyLyricProvider()
    var lRCLyricProvider = LRCLIBLyricProvider()
    var netEaseLyricProvider = NetEaseLyricProvider()
    var lyrics9xLyricProvider = Lyrics9xLyricProvider()
    #if os(macOS)
    @ObservationIgnored lazy var appleMusicLyricProvider = AppleMusicLyricProvider()
    @ObservationIgnored lazy var appleMusicPrefetcher = AppleMusicPrefetcher(
        container: coreDataContainer,
        provider: appleMusicLyricProvider
    )
    var localFileUploadProvider = LocalFileUploadProvider()
    #endif
    // Per-player chain ordering:
    //   .plexamp     → Lyrics9x first (user's self-hosted .lrc library wins;
    //                  syncedlyrics fallback already covers niche artists)
    //   .appleMusic  → Spotify first (its synced lyrics match Apple Music's
    //   .spotify       sync timing well for major-label tracks — same source
    //                  fingerprint for K-pop, J-pop, English pop). Lyrics9x's
    //                  syncedlyrics cascade is a 2nd-choice for what Spotify
    //                  doesn't have. The background `fetchEnrichmentOnly`
    //                  Task still fires regardless, so romanization +
    //                  translation come from Lyrics9x on top of Spotify
    //                  base lyrics.
    var allNetworkLyricProviders: [LyricProvider] {
        #if os(macOS)
        if currentPlayer == .plexamp {
            return [lyrics9xLyricProvider, spotifyLyricProvider, lRCLyricProvider, netEaseLyricProvider]
        }
        if currentPlayer == .appleMusic,
           let amID = appleMusicPlayer.lastObservedCatalogID, !amID.isEmpty,
           AppleMusicAuthManager.shared.isAuthorized {
            return [appleMusicLyricProvider, spotifyLyricProvider, lRCLyricProvider, netEaseLyricProvider]
        }
        return [spotifyLyricProvider, lyrics9xLyricProvider, lRCLyricProvider, netEaseLyricProvider]
        #else
        return [spotifyLyricProvider, lRCLyricProvider, netEaseLyricProvider]
        #endif
    }

    // custom order because LRCLIB is tweaking for the time being
    @ObservationIgnored lazy var allNetworkLyricProvidersForSearch: [LyricProvider] = [spotifyLyricProvider, netEaseLyricProvider, lRCLyricProvider]
    
    var isFirstFetch = true
    
    init() {
        // Set our user locale for translation language
        systemLocale = Locale.preferredLocale()
        systemLocaleString = Locale.preferredLocaleString() ?? ""
        
        #if os(macOS)
        // Generate user-saved font and load it
        let karaokeFontSize: Double = UserDefaults.standard.double(forKey: "karaokeFontSize")
        let karaokeFontName: String? = UserDefaults.standard.string(forKey: "karaokeFontName")
        if let karaokeFontName, karaokeFontSize != 0, let ourKaraokeFont = NSFont(name: karaokeFontName, size: karaokeFontSize) {
            karaokeFont = ourKaraokeFont
        } else {
            karaokeFont = NSFont.boldSystemFont(ofSize: 30)
        }
        #endif
        
        
        // Load our CoreData container for Lyrics
        coreDataContainer = NSPersistentContainer(name: "Lyrics")
        
        initAppleMusicWorkaround()
        #if os(macOS)
        initPlexampObservation()
        initMusicAssistantObservation()
        #endif
        
        coreDataContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Error: \(error.localizedDescription)")
            }
            self.coreDataContainer.viewContext.mergePolicy = NSMergePolicy.overwrite
        }
        #if os(macOS)
        migrateTimestampsIfNeeded(context: coreDataContainer.viewContext)
        
        
        // Check if user must urgently update (overrides menubar)
        Task {
            mustUpdateUrgent = await updaterService.urgentUpdateExists
        }
        
        // onAppear()
        print("on appear running")
        if userDefaultStorage.latestUpdateWindowShown < 23 {
            return
        }
        #endif
        if userDefaultStorage.cookie.count == 0 {
            print("Setting hasOnboarded to false due to empty cookie")
            userDefaultStorage.hasOnboarded = false
            return
        }
        guard userDefaultStorage.hasOnboarded else {
            return
        }
        guard isPlayerRunning else {
            return
        }
        print("Application just started. lets check whats playing")
        
        isPlaying = currentPlayerInstance.isPlaying
        userDefaultStorage.hasOnboarded = currentPlayerInstance.isAuthorized
        KeyboardShortcuts.onKeyUp(for: .init("karaoke")) { [self] in
            userDefaultStorage.karaoke.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .init("lyrics")) { [self] in
            showLyrics.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .init("translate")) { [self] in
            userDefaultStorage.translate.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .init("romanize")) { [self] in
            userDefaultStorage.romanize.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .init("fullscreen")) { [self] in
            displayFullscreen.toggle()
        }
        guard userDefaultStorage.hasOnboarded else {
            return
        }
        
    }
    
    @MainActor
    func fetchAllNetworkLyrics() async -> NetworkFetchReturn {
        guard let currentlyPlaying, let currentlyPlayingName else {
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        print("FetchAllNetworkLyrics: chain order = \(allNetworkLyricProviders.map { $0.providerName })")
        for networkLyricProvider in allNetworkLyricProviders {
            do {
                print("FetchAllNetworkLyrics: fetching from \(networkLyricProvider.providerName)")
                let providerTrackID: String = {
                    if networkLyricProvider.providerName == "apple_music" {
                        return appleMusicPlayer.lastObservedCatalogID ?? ""
                    }
                    return currentlyPlaying
                }()
                let lyrics = try await networkLyricProvider.fetchNetworkLyrics(trackName: currentlyPlayingName, trackID: providerTrackID, currentlyPlayingArtist: currentlyPlayingArtist, currentAlbumName: currentAlbumName)
                if !lyrics.lyrics.isEmpty {
                    amplitude.track(eventType: "\(networkLyricProvider.providerName) Fetch")
                    print("FetchAllNetworkLyrics: returning lyrics from \(networkLyricProvider.providerName)")
                    // thats how i save to coredata
                    let song = SongObject(from: lyrics.lyrics, with: coreDataContainer.viewContext, trackID: currentlyPlaying, trackName: currentlyPlayingName)
                    song.appleMusicID = appleMusicPlayer.lastObservedCatalogID
                    song.albumID = appleMusicPlayer.lastObservedAlbumCatalogID
                    song.sourceProvider = networkLyricProvider.providerName
                    song.userPicked = false
                    saveCoreData()
                    return lyrics
                } else if networkLyricProvider is SpotifyLyricProvider {
                    print("FetchAllNetworkLyrics: no lyrics from \(networkLyricProvider.providerName)")
                    handleSpotifyNoLyricsFallback()
                } else {
                    print("FetchAllNetworkLyrics: no lyrics from \(networkLyricProvider.providerName)")
                }
            } catch {
                print("Caught exception on \(networkLyricProvider.providerName): \(error)")
            }
        }
        // Entire chain returned empty — cache a none_found sentinel so we don't re-query every play
        let noneSong = SongObject(from: [], with: coreDataContainer.viewContext, trackID: currentlyPlaying, trackName: currentlyPlayingName)
        noneSong.appleMusicID = appleMusicPlayer.lastObservedCatalogID
        noneSong.albumID = appleMusicPlayer.lastObservedAlbumCatalogID
        noneSong.sourceProvider = "none_found"
        noneSong.userPicked = false
        saveCoreData()
        return NetworkFetchReturn(lyrics: [], colorData: nil)
    }
    
    #if os(macOS)
    func refreshLyrics() async throws {
        // todo: romanize
        if currentPlayer == .appleMusic {
            print("Refresh Lyrics: Calling Apple Music Network fetch")
            try await appleMusicNetworkFetch()
        }
        guard let currentlyPlaying, let currentlyPlayingName, let currentDuration = currentPlayerInstance.durationAsTimeInterval else {
            return
        }
        print("Calling refresh lyrics")
        guard let finalLyrics = await self.fetch(for: currentlyPlaying, currentlyPlayingName, checkCoreDataFirst: false) else {
            print("Refresh Lyrics: Failed to run network fetch")
            return
        }
        if finalLyrics.isEmpty {
            currentlyPlayingLyricsIndex = nil
        }
        setNewLyricsColorTranslationRomanizationAndStartUpdater(with: finalLyrics)
//        currentlyPlayingLyrics = finalLyrics
//        setBackgroundColor()
//        romanizeDidChange()
//        reloadTranslationConfigIfTranslating()
//        lyricsIsEmptyPostLoad = currentlyPlayingLyrics.isEmpty
//        print("HELLOO")
//        if isPlaying, !currentlyPlayingLyrics.isEmpty, showLyrics, userDefaultStorage.hasOnboarded {
//            startLyricUpdater()
//        }
        // we call this in self.fetch
//        callColorDataServiceOnLyricColorOrArtwork(colorData: finalLyrics.colorData)
    }
    
    func callColorDataServiceOnLyricColorOrArtwork(colorData: Int32?) {
        if currentPlayer == .appleMusic {
            if let currentlyPlaying, let backgroundColor = artworkImage?.findWhiteTextLegibleMostSaturatedDominantColor() {
                ColorDataService.saveColorToCoreData(trackID: currentlyPlaying, songColor: backgroundColor)
                print("ViewModel Refresh Lyrics: New color \(backgroundColor) saved for track \(currentlyPlaying)")
            }
        } else {
            if let currentlyPlaying, let backgroundColor = colorData {
                ColorDataService.saveColorToCoreData(trackID: currentlyPlaying, songColor: backgroundColor)
                print("ViewModel Refresh Lyrics: New color \(backgroundColor) saved for track \(currentlyPlaying)")
            }
        }
    }
    
    // Run only on first 2.1 run. Strips whitespace from saved lyrics, and extends final timestamp to prevent karaoke mode racecondition (as well as song on loop race condition)
    func migrateTimestampsIfNeeded(context: NSManagedObjectContext) {
        if !userDefaultStorage.hasMigrated {
            let fetchRequest: NSFetchRequest<SongObject> = SongObject.fetchRequest()
            do {
                let objects = try context.fetch(fetchRequest)
                for object in objects {
                    var timestamps = object.lyricsTimestamps
                    if let lastIndex = timestamps.indices.last {
                        timestamps[lastIndex] = timestamps[lastIndex] + 5000
                        object.lyricsTimestamps = timestamps
                    }
                    var strings = object.lyricsWords
                    let indicesToRemove = strings.indices.filter { strings[$0].isEmpty }
                    strings.removeAll { $0.isEmpty }
                    for index in indicesToRemove.reversed() {
                        timestamps.remove(at: index)
                    }

                    // Update the object properties
                    object.lyricsWords = strings
                    object.lyricsTimestamps = timestamps
                }
                try context.save()
                
                // Mark migration as done
                userDefaultStorage.hasMigrated = true
            } catch {
                print("Error migrating data: \(error)")
            }
        }
    }
    
    // Runs once user has completed Spotify log-in. Attempt to extract cookie
    func checkIfLoggedIn() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            if let temporaryCookie = cookies.first(where: {$0.name == "sp_dc"}) {
                print("found the sp_dc cookie")
                self.userDefaultStorage.cookie = temporaryCookie.value
                NotificationCenter.default.post(name: Notification.Name("didLogIn"), object: nil)
            }
        }
    }
    
    func openSettings(_ openWindow: OpenWindowAction) {
        openWindow(id: "onboarding")
        NSApplication.shared.activate(ignoringOtherApps: true)
//        // send notification to check auth
//        NotificationCenter.default.post(name: Notification.Name("didClickSettings"), object: nil)
    }
    #endif
    
    func toggleLyrics() {
        if showLyrics {
            startLyricUpdater()
        } else {
            stopLyricUpdater()
        }
    }
    
    func openTranslationHelpOnFirstRun(_ openURL: OpenURLAction) {
        if !userDefaultStorage.hasTranslated {
            openURL(URL(string: "https://aviwadhwa.com/TranslationHelp")!)
        }
        userDefaultStorage.hasTranslated = true
    }
    
    @MainActor
    func translationTask(_ session: TranslationSession) async {
        isFetchingTranslation = true
        let translationResponse = await TranslationService.translationTask(session, request: currentlyPlayingLyrics.map { TranslationSession.Request(lyric: $0) })
        
        switch translationResponse {
            case .success(let array):
                print("Translation Service: isFetchingTranslation set to false due to success")
                isFetchingTranslation = false
                if currentlyPlayingLyrics.count == array.count {
                    translatedLyric = array.map {
                        $0.targetText
                    }
                }
            case .needsConfigUpdate(let language):
                // TODO: why do i sleep?
//                try? await Task.sleep(for: .seconds(1))
                translationSessionConfig = TranslationSession.Configuration(source: language, target: userLocaleLanguage)
            case .failure:
                print("Translation Service: isFetchingTranslation set to false due to failure")
                isFetchingTranslation = false
                return
        }
    }
    
    func romanizeDidChange() {
        if userDefaultStorage.romanize {
            // Prefer server-side romanization from Lyrics9x (pykakasi for JA,
            // hangul-romanize for KO) — it covers Korean which Mecab can't,
            // and is per-line aligned by timestamp at the kaiosmini side.
            if let serverRom = lastNetworkResult?.romanization,
               !serverRom.isEmpty,
               serverRom.count == currentlyPlayingLyrics.count {
                print("Romanized Lyrics from Lyrics9x server enrichment (\(serverRom.count) lines, lang=\(lastNetworkResult?.language ?? "?"))")
                romanizedLyrics = serverRom
                return
            }
            // Generate romanized lyrics from chinese conversion
            if !chineseConversionLyrics.isEmpty {
                print("Romanized Lyrics generated from romanize value change for song \(String(describing: currentlyPlaying)) with chinese conversion")
                romanizedLyrics = chineseConversionLyrics.compactMap({
                    RomanizerService.generateRomanizedLyric(LyricLine(startTime: 0, words: $0))
                })
            // Generate romanized lyrics from original lyrics
            } else {
                print("Romanized Lyrics generated from romanize value change for song \(String(describing: currentlyPlaying))")
                romanizedLyrics = currentlyPlayingLyrics.compactMap({
                    RomanizerService.generateRomanizedLyric($0)
                })
            }

//            romanizeMetadata()
        } else {
            romanizedLyrics = []
        }
    }
    
    // Only called when Romanize is true
//    func romanizeMetadata() {
//        // Generate romanized metadata from name & artist
//        if userDefaultStorage.romanizeMetadata, let currentlyPlayingName, let romanizedName = RomanizerService.generateRomanizedString(currentlyPlayingName), let currentlyPlayingArtist, let romanizedArtist = RomanizerService.generateRomanizedString(currentlyPlayingArtist) {
//            self.currentlyPlayingName = romanizedName
//            self.currentlyPlayingArtist = romanizedArtist
//        }
//    }
    
    func romanizeName(_ currentlyPlayingName: String) -> String? {
        if let romanizedName = RomanizerService.generateRomanizedString(currentlyPlayingName) {
            return romanizedName
        }
        return nil
    }
    
    func romanizeArtist(_ currentlyPlayingArtist: String) -> String? {
        if let romanizedArtist = RomanizerService.generateRomanizedString(currentlyPlayingArtist) {
            return romanizedArtist
        }
        return nil
    }
    
    func chinesePreferenceDidChange() {
        if let chinesePreference = ChineseConversion(rawValue: userDefaultStorage.chinesePreference), chinesePreference != .none {
            print("Generating Chinese conversion for song \(String(describing: currentlyPlaying)) to chinese style \(chinesePreference.description)")
            //TODO: check if Task was cancelled
            let chineseConversionLyrics: [String] = currentlyPlayingLyrics.compactMap({
                switch chinesePreference {
                    case .none:
                        return nil
                    case .simplified:
                        return RomanizerService.generateMainlandTransliteration($0)
                    case .traditionalNeutral:
                        return RomanizerService.generateTraditionalNeutralTransliteration($0)
                    case .traditionalTaiwan:
                        return RomanizerService.generateTaiwanTransliteration($0)
                    case .traditionalHK:
                        return RomanizerService.generateHongKongTransliteration($0)
                }
            })
            //TODO: check if Task was cancelled
            if !Task.isCancelled {
                self.chineseConversionLyrics = chineseConversionLyrics
            }
        } else {
            chineseConversionLyrics = []
        }
    }
    
    #if os(macOS)
    func saveKaraokeFontOnTermination() {
        // This code will be executed just before the app terminates
     UserDefaults.standard.set(karaokeFont.fontName, forKey: "karaokeFontName")
     UserDefaults.standard.set(Double(karaokeFont.pointSize), forKey: "karaokeFontSize")
    }
    
    func appleMusicPlaybackDidChange(_ notification: Notification) {
        guard currentPlayer == .appleMusic else {
            return
        }
        if notification.userInfo?["Player State"] as? String == "Playing" {
            print("is playing")
            isPlaying = true
        } else {
            print("paused. timer canceled")
            isPlaying = false
            // manually cancels the lyric-updater task bc media is paused
        }
        let currentlyPlayingName = (notification.userInfo?["Name"] as? String)
        guard let currentlyPlayingName else {
            self.currentlyPlayingName = nil
            currentlyPlayingArtist = nil
            currentAlbumName = nil
            return
        }
        if currentlyPlayingName == "" {
            self.currentlyPlayingName = nil
            currentlyPlayingArtist = nil
            currentAlbumName = nil
        } else {
            let nameChanged = self.currentlyPlayingName != currentlyPlayingName
            self.currentlyPlayingName = currentlyPlayingName
            currentlyPlayingArtist = (notification.userInfo?["Artist"] as? String)
            currentAlbumName = (notification.userInfo?["Album"] as? String)
            if let duration = currentPlayerInstance.duration {
                self.duration = duration
            }
            print("REOPEN: currentlyPlayingName is \(currentlyPlayingName) (nameChanged=\(nameChanged))")
            // Prefer the persistent-ID embedded in the notification — it changes
            // exactly when the track changes. Fall back to reading appleMusicPlayer's
            // AppleScript currentTrack reference, which can lag the notification by
            // several hundred ms (Music.app keeps the old reference for a moment
            // mid-transition). Without this fallback retry, .task(id: persistentID)
            // doesn't fire for the new track and stale lyrics stick.
            let notifPID = appleMusicPersistentIDFromUserInfo(notification.userInfo)
            if let notifPID, currentlyPlayingAppleMusicPersistentID != notifPID {
                currentlyPlayingAppleMusicPersistentID = notifPID
            } else if nameChanged {
                // Notification didn't carry a PersistentID we recognized but the
                // name changed — definitely a new track. Drive a retry loop until
                // the AppleScript persistent ID reflects it.
                refreshApplePersistentIDUntilChanged(from: currentlyPlayingAppleMusicPersistentID, attemptsLeft: 8)
            } else {
                currentlyPlayingAppleMusicPersistentID = appleMusicPlayer.persistentID
            }
        }
    }

    /// Music.app's `com.apple.Music.playerInfo` notification sometimes
    /// includes the new track's persistent ID directly so we don't have to
    /// race AppleScript. Key name + value type vary across macOS versions —
    /// accept "PersistentID", "Persistent ID", and both String and NSNumber.
    private func appleMusicPersistentIDFromUserInfo(_ info: [AnyHashable: Any]?) -> String? {
        guard let info else { return nil }
        for key in ["PersistentID", "Persistent ID"] {
            if let s = info[key] as? String, !s.isEmpty { return s }
            if let n = info[key] as? NSNumber {
                return String(format: "%016llX", n.uint64Value)
            }
        }
        return nil
    }

    /// Polls `appleMusicPlayer.persistentID` until it differs from `from` or
    /// the attempt budget is exhausted. Music.app generally catches up within
    /// 200-500ms; budget of 8 × 250ms = 2s is safely beyond worst-case.
    private func refreshApplePersistentIDUntilChanged(from oldPID: String?, attemptsLeft: Int) {
        let fresh = appleMusicPlayer.persistentID
        if fresh != nil, fresh != oldPID {
            currentlyPlayingAppleMusicPersistentID = fresh
            return
        }
        guard attemptsLeft > 0 else {
            print("refreshApplePersistentIDUntilChanged: gave up; AppleScript never updated past \(oldPID ?? "nil")")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshApplePersistentIDUntilChanged(from: oldPID, attemptsLeft: attemptsLeft - 1)
        }
    }
    
    func spotifyPlaybackDidChange(_ notification: Notification) {
        guard currentPlayer == .spotify else {
            return
        }
        if notification.userInfo?["Player State"] as? String == "Stopped" {
            currentLyricsDriftFix?.cancel()
            isPlaying = false
            isStopped = true
            return
        }
        isStopped = false
        if notification.userInfo?["Player State"] as? String == "Playing" {
            print("is playing")
            isPlaying = true
        } else {
            print("paused. timer canceled")
            isPlaying = false
            // manually cancels the lyric-updater task bc media is paused
        }
        print(notification.userInfo?["Track ID"] as? String)
        let currentlyPlaying = (notification.userInfo?["Track ID"] as? String)?.spotifyProcessedUrl()
        let currentlyPlayingName = (notification.userInfo?["Name"] as? String)
        if currentlyPlaying != "", currentlyPlayingName != "", let duration = currentPlayerInstance.duration {
            self.currentlyPlaying = currentlyPlaying
            self.currentlyPlayingName = currentlyPlayingName
            self.currentlyPlayingArtist = spotifyPlayer.artistName
            self.currentAlbumName = spotifyPlayer.albumName
            self.duration = duration
        }
    }
    
    func onAppear(_ openWindow: OpenWindowAction) {
        setCurrentProperties()
    }
    
    func onCurrentlyPlayingIDChange() async {
        currentlyPlayingLyricsIndex = nil
        currentlyPlayingLyrics = []
        translatedLyric = []
        romanizedLyrics = []
        chineseConversionLyrics = []

        print("onCurrentlyPlayingIDChange: hasOnboarded=\(userDefaultStorage.hasOnboarded) currentlyPlaying=\(currentlyPlaying ?? "nil") currentlyPlayingName=\(currentlyPlayingName ?? "nil")")
        if userDefaultStorage.hasOnboarded, let currentlyPlaying = currentlyPlaying, let currentlyPlayingName = currentlyPlayingName, let lyrics = await fetch(for: currentlyPlaying, currentlyPlayingName) {
            print("onCurrentlyPlayingIDChange: fetched \(lyrics.count) lyric lines")
            setNewLyricsColorTranslationRomanizationAndStartUpdater(with: lyrics)
            // After lyrics are showing (regardless of source — CoreData, Spotify,
            // LRCLIB, etc.), kick off a parallel enrichment fetch against Lyrics9x
            // for romanization + translation. This is what makes the 3-tier display
            // work even for tracks the user has played before and CoreData-cached.
            // Background; doesn't block the lyrics from appearing.
            let snapshotTrack = currentlyPlaying
            let snapshotName = currentlyPlayingName
            let snapshotArtist = currentlyPlayingArtist
            let snapshotAlbum = currentAlbumName
            let snapshotLyrics = self.currentlyPlayingLyrics
            Task { [weak self] in
                guard let self else { return }
                do {
                    let (rom, trn, lang) = try await self.lyrics9xLyricProvider.fetchEnrichmentOnly(
                        trackName: snapshotName,
                        artist: snapshotArtist,
                        album: snapshotAlbum,
                        existingLyrics: snapshotLyrics
                    )
                    await MainActor.run {
                        // Only apply if the track hasn't changed under us.
                        guard self.currentlyPlaying == snapshotTrack else { return }
                        if let rom, !rom.isEmpty {
                            self.romanizedLyrics = rom
                        }
                        if let trn, !trn.isEmpty {
                            self.translatedLyric = trn
                            // Clear the "loading" state and cancel any in-flight
                            // Apple Translation request — we now have the server
                            // translation, no need to keep Apple Translation
                            // spinning (it would also overwrite our server data
                            // when it finally returns).
                            self.isFetchingTranslation = false
                            #if os(macOS)
                            self.translationSessionConfig?.invalidate()
                            #endif
                        }
                        if rom != nil || trn != nil {
                            print("Lyrics9x background enrichment applied (lang=\(lang ?? "?"))")
                        }
                    }
                } catch {
                    print("Lyrics9x background enrichment failed: \(error)")
                }
            }
//            currentlyPlayingLyrics = lyrics
//            setBackgroundColor()
//            romanizeDidChange()
//            reloadTranslationConfigIfTranslating()
//            lyricsIsEmptyPostLoad = lyrics.isEmpty
//            if isPlaying, !currentlyPlayingLyrics.isEmpty, showLyrics, userDefaultStorage.hasOnboarded {
//                print("STARTING UPDATER")
//                startLyricUpdater()
//            }
        }
    }
    
    /// Public shim so SwiftUI scenes can ask us to re-detect the active
    /// player's current track (used when smart-player routing flips between
    /// Plexamp / Apple Music / Spotify based on which app is actively
    /// playing). Forwards to the existing private `setCurrentProperties`.
    func setCurrentPropertiesPublic() {
        setCurrentProperties()
    }

    private func setCurrentProperties() {
        switch currentPlayer {
            case .appleMusic:
                if let currentTrackName = appleMusicPlayer.trackName, let currentArtistName = appleMusicPlayer.artistName, let duration = appleMusicPlayer.duration, let currentAlbumName = appleMusicPlayer.albumName {
                    // Don't set currentlyPlaying here: the persistentID change triggers the appleMusicFetch which will set spotify's currentlyPlaying
                    if currentTrackName == "" {
                        currentlyPlayingName = nil
                        currentlyPlayingArtist = nil
                        self.currentAlbumName = nil
                    } else {
                        currentlyPlayingName = currentTrackName
                        currentlyPlayingArtist = currentArtistName
                        self.duration = duration
                        self.currentAlbumName = currentAlbumName
                    }
                    print("ON APPEAR HAS UPDATED APPLE MUSIC SONG ID")
                    currentlyPlayingAppleMusicPersistentID = appleMusicPlayer.persistentID
                }
            case .spotify:
                if let currentTrack = spotifyPlayer.trackID, let currentTrackName = spotifyPlayer.trackName, let currentArtistName =  spotifyPlayer.artistName, currentTrack != "", currentTrackName != "", let duration = spotifyPlayer.duration, let currentAlbumName = spotifyPlayer.albumName {
                    currentlyPlaying = currentTrack
                    currentlyPlayingName = currentTrackName
                    currentlyPlayingArtist = currentArtistName
                    self.duration = duration
                    self.currentAlbumName = currentAlbumName
                    self.currentTime = CurrentTimeWithStoredDate(currentTime: 0)
                    print(currentTrack)
                }
            case .plexamp:
                print("setCurrentProperties: Plexamp branch — trackName=\(plexampPlayer.trackName ?? "nil") artistName=\(plexampPlayer.artistName ?? "nil") duration=\(plexampPlayer.duration ?? -1) albumName=\(plexampPlayer.albumName ?? "nil") metadata.ratingKey=\(plexampPlayer.metadata?.ratingKey ?? "nil")")
                guard let track = plexampPlayer.trackName, let artist = plexampPlayer.artistName, let duration = plexampPlayer.duration else {
                    print("setCurrentProperties: Plexamp guard failed — clearing currentlyPlaying state")
                    currentlyPlayingName = nil
                    currentlyPlayingArtist = nil
                    self.currentAlbumName = nil
                    return
                }
                print("setCurrentProperties: Plexamp guard passed — setting currentlyPlaying=\(plexampPlayer.metadata?.ratingKey ?? "nil")")
                // Plexamp's ratingKey is the stable per-song identifier; use it for `currentlyPlaying`
                // so the upstream song-change Task fires on track changes.
                currentlyPlaying = plexampPlayer.metadata?.ratingKey
                currentlyPlayingName = track
                currentlyPlayingArtist = artist
                self.duration = duration
                self.currentAlbumName = plexampPlayer.albumName
                self.currentTime = CurrentTimeWithStoredDate(currentTime: 0)
                // Background-preload every OTHER track in the active play queue so
                // when the user hits next, the lyrics are already enriched + cached
                // on kaiosmini. Cheap: each call returns <500ms from cache after
                // the first lookup ever per track.
                preloadPlexampQueueLyrics(excluding: plexampPlayer.metadata?.ratingKey)
            case .musicAssistant:
                guard let track = musicAssistantPlayer.trackName, let artist = musicAssistantPlayer.artistName, let duration = musicAssistantPlayer.duration else {
                    currentlyPlayingName = nil
                    currentlyPlayingArtist = nil
                    self.currentAlbumName = nil
                    return
                }
                // MA's queue_item_id is a stable per-play identifier — same role
                // as Plexamp's ratingKey, more reliable than Apple Music's
                // MediaRemote persistentID.
                currentlyPlaying = musicAssistantPlayer.activeQueueId.flatMap { musicAssistantPlayer.queues[$0]?.queueItemId }
                currentlyPlayingName = track
                currentlyPlayingArtist = artist
                self.duration = duration
                self.currentAlbumName = musicAssistantPlayer.albumName
                self.currentTime = CurrentTimeWithStoredDate(currentTime: 0)
        }
    }

    /// For each sibling track in Plexamp's active PlayQueue (artist+title in
    /// the on-disk PlayQueue.json), fire a non-blocking /api/lookup so the
    /// kaiosmini enrichment + cache is warm by the time the user navigates to
    /// each one. Skips the currently-playing ratingKey. Best-effort; failures
    /// are silent.
    /// Jump playback to the start of a specific lyric line. Routes to
    /// whatever currentPlayer is active (Apple Music / Spotify via
    /// ScriptingBridge, Plexamp via HTTP control API). Also moves our local
    /// lyric-index pointer so highlight + scroll catch up immediately
    /// instead of waiting for the next playback-position poll cycle.
    func seekToLyricLine(at index: Int) {
        guard index >= 0, index < currentlyPlayingLyrics.count else { return }
        let line = currentlyPlayingLyrics[index]
        let ms = Int(line.startTimeMS)
        currentPlayerInstance.seek(toMillis: ms)
        currentlyPlayingLyricsIndex = index
        // Re-anchor currentTime so the lyric-updater task computes the right delta.
        currentTime = CurrentTimeWithStoredDate(currentTime: Double(ms))
        if !isPlaying {
            currentPlayerInstance.togglePlayback()
        }
    }

    /// "End-of-track" enrichment preloader. Runs every 10s while a track is
    /// playing; once `duration - currentTime <= 60s` it fires preload for the
    /// upcoming track(s). Per-trackID guard prevents repeated firing within
    /// the same song. Reset by setCurrentProperties on the next track change.
    private var endOfTrackPreloadTask: Task<Void, Never>?
    private var endOfTrackPreloadedFor: String? = nil

    func startEndOfTrackPreloader() {
        endOfTrackPreloadTask?.cancel()
        endOfTrackPreloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run { [weak self] in
                    self?.checkEndOfTrackAndPreload()
                }
            }
        }
    }

    func checkEndOfTrackAndPreload() {
        guard let track = currentlyPlaying else { return }
        guard endOfTrackPreloadedFor != track else { return }
        guard let duration = currentPlayerInstance.duration, duration > 0 else { return }
        guard let pos = currentPlayerInstance.currentTime else { return }
        let remainingMs = Double(duration) - pos
        // Fire when 60s or less remains. Don't fire on a fresh-started track
        // (remaining ≈ duration > 60s).
        guard remainingMs < 60_000, remainingMs > 0 else { return }
        endOfTrackPreloadedFor = track
        print("End-of-track preload triggered for \(track) (remaining ~\(Int(remainingMs/1000))s)")
        // Re-run the existing Plexamp queue preload (it skips the currently-playing
        // ratingKey itself, so all upcoming siblings — including any added since
        // the last setCurrentProperties run — get warmed).
        if currentPlayer == .plexamp {
            preloadPlexampQueueLyrics(excluding: plexampPlayer.metadata?.ratingKey)
        }
        // Apple Music's queue API isn't reliably scriptable on modern macOS
        // (Up Next isn't enumerable). For Apple Music we rely on per-track
        // first-play enrichment (5-20s cold, instant cached). If the user plays
        // through an album, by track 2 onwards the cache is already filling.
    }

    func preloadPlexampQueueLyrics(excluding currentRatingKey: String?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Plexamp/PlayQueue.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let container = payload["MediaContainer"] as? [String: Any],
              let items = container["Metadata"] as? [[String: Any]] else { return }

        struct Sibling { let key: String; let title: String; let artist: String; let album: String? }
        var siblings: [Sibling] = []
        for item in items {
            let k: String? = {
                if let s = item["ratingKey"] as? String { return s }
                if let n = item["ratingKey"] as? NSNumber { return n.stringValue }
                return nil
            }()
            guard let k, k != currentRatingKey,
                  let title = item["title"] as? String,
                  let artist = item["grandparentTitle"] as? String,
                  !title.isEmpty, !artist.isEmpty else { continue }
            let album = item["parentTitle"] as? String
            siblings.append(Sibling(key: k, title: title, artist: artist, album: album))
        }
        guard !siblings.isEmpty else { return }
        print("preloadPlexampQueueLyrics: warming \(siblings.count) sibling track(s)")
        Task.detached(priority: .utility) {
            let session = URLSession(configuration: .default)
            for sib in siblings {
                var items: [URLQueryItem] = [
                    URLQueryItem(name: "artist_name", value: sib.artist),
                    URLQueryItem(name: "track_name", value: sib.title),
                ]
                if let album = sib.album, !album.isEmpty {
                    items.append(URLQueryItem(name: "album_name", value: album))
                }
                var comps = URLComponents(string: "http://100.114.244.6:8676")!
                comps.path = "/api/lookup"
                comps.queryItems = items
                guard let url = comps.url else { continue }
                _ = try? await session.data(for: URLRequest(url: url))
            }
            print("preloadPlexampQueueLyrics: done warming")
        }
    }
    
    #else
    func setCurrentProperties() {
        currentlyPlaying = spotifyPlayer.currentTrack?.uri?.spotifyProcessedUrl()
        currentlyPlayingName = spotifyPlayer.trackName
        currentlyPlayingArtist = spotifyPlayer.artistName
    }
    #endif

    func upcomingIndex(_ currentTime: Double) -> Int? {
        if let currentlyPlayingLyricsIndex {
            let newIndex = currentlyPlayingLyricsIndex + 1
            if newIndex >= currentlyPlayingLyrics.count {
                print("REACHED LAST LYRIC!!!!!!!!")
                // if current time is before our current index's start time, the user has scrubbed and rewinded
                // reset into linear search mode
                if currentTime < currentlyPlayingLyrics[currentlyPlayingLyricsIndex].startTimeMS {
                    return currentlyPlayingLyrics.firstIndex(where: {$0.startTimeMS > currentTime})
                }
                // we've reached the end of the song, we're past the last lyric
                //TODO: remove these
                #if os(macOS)
                currentlyPlayingAppleMusicPersistentID = nil
                #endif
                currentlyPlaying = nil
                return nil
            }
            else if  currentTime > currentlyPlayingLyrics[currentlyPlayingLyricsIndex].startTimeMS, currentTime < currentlyPlayingLyrics[newIndex].startTimeMS {
                print("just the next lyric")
                return newIndex
            }
        }
        // linear search through the array to find the first lyric that's right after the current time
        // done on first lyric update for the song, as well as post-scrubbing
        return currentlyPlayingLyrics.firstIndex(where: {$0.startTimeMS > currentTime})
    }
    
    func lyricUpdater() async throws {
        repeat {
            guard let currentTime = currentPlayerInstance.currentTime, let lastIndex: Int = upcomingIndex(currentTime) else {
                stopLyricUpdater()
                return
            }
            // If there is no current index (perhaps lyric updater started late and we're mid-way of the first lyric, or the user scrubbed and our index is expired)
            // Then we set the current index to the one before our anticipated index
            if currentlyPlayingLyricsIndex == nil && lastIndex > 0 {
                currentlyPlayingLyricsIndex = lastIndex-1
            }
            let nextTimestamp = currentlyPlayingLyrics[lastIndex].startTimeMS
            let diff = nextTimestamp - currentTime
            print("current time: \(currentTime)")
            self.currentTime = CurrentTimeWithStoredDate(currentTime: currentTime)
            print("next time: \(nextTimestamp)")
            print("the difference is \(diff)")
            try await Task.sleep(nanoseconds: UInt64(1000000*diff))
            print("lyrics exist: \(!currentlyPlayingLyrics.isEmpty)")
            print("last index: \(lastIndex)")
            print("currently playing lryics index: \(currentlyPlayingLyricsIndex)")
            if currentlyPlayingLyrics.count > lastIndex {
                currentlyPlayingLyricsIndex = lastIndex
            } else {
                currentlyPlayingLyricsIndex = nil
                
            }
            print(currentlyPlayingLyricsIndex ?? "nil")
        } while !Task.isCancelled
    }
    
    func startLyricUpdater() {
        currentLyricsUpdaterTask?.cancel()
        if !isPlaying || currentlyPlayingLyrics.isEmpty || mustUpdateUrgent {
            return
        }
        // If an index exists, we're unpausing: meaning we must instantly find the current lyric
        if currentlyPlayingLyricsIndex != nil {
            guard let currentTime = currentPlayerInstance.currentTime, let lastIndex: Int = upcomingIndex(currentTime) else {
                stopLyricUpdater()
                return
            }
            // If there is no current index (perhaps lyric updater started late and we're mid-way of the first lyric, or the user scrubbed and our index is expired)
            // Then we set the current index to the one before our anticipated index
            if lastIndex > 0 {
                currentlyPlayingLyricsIndex = lastIndex-1
            }
        } else {
            #if os(macOS)
            if currentPlayer == .spotify {
                currentLyricsDriftFix?.cancel()
                currentLyricsDriftFix =             // Only run drift fix for new songs
                Task {
                    try await spotifyPlayer.fixSpotifyLyricDrift()
                }
                Task {
                    try await currentLyricsDriftFix?.value
                }
            }
            #endif
        }
        currentLyricsUpdaterTask = Task {
            do {
                try await lyricUpdater()
            } catch {
                print("lyrics were canceled \(error)")
            }
        }
        Task {
            try await currentLyricsUpdaterTask?.value
        }
        
    }
    
    func stopLyricUpdater() {
        print("stop called")
        currentLyricsUpdaterTask?.cancel()
    }
    
    func saveCoreData() {
        let context = coreDataContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
                print("Saved CoreData!")
            } catch {
                print("core data error \(error)")
                // Show some error here
            }
        } else {
            print("BAD COREDATA CALL!!")
        }
    }
    
    func fetch(for trackID: String, _ trackName: String, checkCoreDataFirst: Bool = true) async -> [LyricLine]? {
        if isFirstFetch {
            isFirstFetch = false
        }
        print("Fetch Called for trackID \(trackID), trackName \(trackName), checkCoreDataFirst: \(checkCoreDataFirst)")
        currentFetchTask?.cancel()
        // i don't set isFetching to true here to prevent "flashes" for CoreData fetches
        defer {
            isFetching = false
        }
        currentFetchTask = Task { try await self.fetchLyrics(for: trackID, trackName, checkCoreDataFirst: checkCoreDataFirst) }
        do {
            return try await currentFetchTask?.value
        } catch {
            print("error \(error)")
            return nil
        }
    }

    #if os(macOS)
    func intToRGB(_ value: Int32) -> Color {//(red: Int, green: Int, blue: Int) {
        // Convert negative numbers to an unsigned 32-bit representation
        let unsignedValue = UInt32(bitPattern: value)
        
        // Extract RGB components
        let red = Double((unsignedValue >> 16) & 0xFF)
        let green = Double((unsignedValue >> 8) & 0xFF)
        let blue = Double(unsignedValue & 0xFF)
        return Color(red: red/255, green: green/255, blue: blue/255) //(red, green, blue)
    }
    
    func setBackgroundColor() {
        guard let currentlyPlaying else {
            return
        }
        let fetchRequest: NSFetchRequest<IDToColor> = IDToColor.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", currentlyPlaying) // Replace trackID with the desired value

        do {
            let results = try coreDataContainer.viewContext.fetch(fetchRequest)
            if let idToColor = results.first {
                self.currentBackground = intToRGB(idToColor.songColor)
            } else {
                self.currentBackground = nil
            }
        } catch {
            print("Error fetching SongObject:", error)
        }
    }
    
    func handleSpotifyNoLyricsFallback() {
        // We know Spotify won’t give us a color for this track
        guard let currentlyPlaying else { return }
        
        guard let colorInt = artworkImage?.findWhiteTextLegibleMostSaturatedDominantColor() else {
            return
        }
        
        ColorDataService.saveColorToCoreData(trackID: currentlyPlaying, songColor: colorInt)
        currentBackground = intToRGB(colorInt)
    }
    #endif
    
    func fetchLyrics(for trackID: String, _ trackName: String, checkCoreDataFirst: Bool) async throws -> [LyricLine] {
        let initiatingTrackID = trackID
        
        // AppleMusic catalog-ID CoreData lookup: when the player is Apple Music
        // and we have a catalog ID, check by appleMusicID first — this covers the
        // case where the same track was previously fetched under a different
        // Spotify/Plexamp trackID but is now playing via Apple Music.
        if checkCoreDataFirst,
           let amID = appleMusicPlayer.lastObservedCatalogID, !amID.isEmpty {
            let request = SongObject.fetchRequest()
            request.predicate = NSPredicate(format: "appleMusicID == %@", amID)
            if let existing = try? coreDataContainer.viewContext.fetch(request).first,
               !existing.lyricsWords.isEmpty || existing.userPicked || existing.sourceProvider == "none_found" {
                let lyrics = zip(existing.lyricsTimestamps, existing.lyricsWords).map { LyricLine(startTime: $0, words: $1) }
                // sticky: skip network chain entirely if userPicked or none_found
                if existing.userPicked || existing.sourceProvider == "none_found" {
                    try Task.checkCancellation()
                    amplitude.track(eventType: "CoreData Fetch (appleMusicID sticky)")
                    if initiatingTrackID != self.currentlyPlaying {
                        throw FetchError.staleTrack
                    }
                    return lyrics
                }
                // cache hit but refetchable — return the cached lyrics
                try Task.checkCancellation()
                amplitude.track(eventType: "CoreData Fetch (appleMusicID)")
                if initiatingTrackID != self.currentlyPlaying {
                    throw FetchError.staleTrack
                }
                return lyrics
            }
        }

        // Self-heal: treat an empty CoreData entry as a miss so we retry the
        // network chain (now with Lyrics9x first → kaiosmini's lookup cascade,
        // which can rescue tracks that earlier providers had no lyrics for, like
        // niche artists added since the last attempt). lyric-fetch caches its own
        // 404s server-side so genuinely-empty tracks still resolve in <500ms on
        // subsequent retries.
        if checkCoreDataFirst, let lyrics = fetchFromCoreData(for: trackID), !lyrics.isEmpty {
            print("ViewModel FetchLyrics: got lyrics from core data :D \(trackID) \(trackName)")
            try Task.checkCancellation()
            amplitude.track(eventType: "CoreData Fetch")
            // verify non-stale trackID
            if initiatingTrackID != self.currentlyPlaying {
                print("FetchLyrics: CoreData result stale (initiated: \(initiatingTrackID), current: \(self.currentlyPlaying ?? "nil")). Throwing.")
                throw FetchError.staleTrack
            }
            return lyrics
        } else {
            print("ViewModel FetchLyrics: empty/missing CoreData entry for \(trackID) — falling through to network (self-heal)")
            print("ViewModel FetchLyrics: no lyrics from core data, going to download from internet \(trackID) \(trackName)")
            print("ViewModel FetchLyrics: isFetching set to true")
            isFetching = true
            
            var networkLyrics: NetworkFetchReturn = await fetchAllNetworkLyrics()
            
            // verify non-stale trackID
            if initiatingTrackID != self.currentlyPlaying {
                print("FetchLyrics: Network result stale (initiated: \(initiatingTrackID), current: \(self.currentlyPlaying ?? "nil")). Throwing.")
                throw FetchError.staleTrack
            }
            
            guard let duration = currentPlayerInstance.duration else {
                print("FetchLyrics: Couldn't access current player duration. Giving up on netwokr fetch")
                return []
            }
            networkLyrics = networkLyrics.processed(withSongName: trackName, duration: duration)
            // Stash the full POST-processed result so romanizeDidChange and the
            // translation flow can read server enrichment with arrays aligned
            // 1:1 with the post-filter currentlyPlayingLyrics.
            self.lastNetworkResult = networkLyrics
            
            // verify non-stale trackID
            if initiatingTrackID == self.currentlyPlaying {
                callColorDataServiceOnLyricColorOrArtwork(colorData: networkLyrics.colorData)
            } else {
                print("FetchLyrics: Skipping color save due to stale track (initiated: \(initiatingTrackID), current: \(self.currentlyPlaying ?? "nil")).")
                throw FetchError.staleTrack
            }
            return networkLyrics.lyrics
        }
    }
    
    func deleteSongLocalePairing(trackID: String) {
        do {
            let fetchRequest: NSFetchRequest<SongToLocale> = SongToLocale.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", trackID)
            guard let object = try coreDataContainer.viewContext.fetch(fetchRequest).first else { return print("Translation: No songToLocale object could be deleted, doesn't exist for trackID \(trackID)") }
            coreDataContainer.viewContext.delete(object)
            try coreDataContainer.viewContext.save()
        } catch {
            print("Error deleting data: \(error)")
        }
    }

    func deleteLyric(trackID: String) {
        do {
            let fetchRequest: NSFetchRequest<SongObject> = SongObject.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", trackID)
            let object = try coreDataContainer.viewContext.fetch(fetchRequest).first
            object?.lyricsTimestamps.removeAll()
            object?.lyricsWords.removeAll()
            try coreDataContainer.viewContext.save()
            currentlyPlayingLyricsIndex = nil
            currentlyPlayingLyrics = []
            translatedLyric = []
            romanizedLyrics = []
            chineseConversionLyrics = []
            lyricsIsEmptyPostLoad = true
        } catch {
            print("Error deleting data: \(error)")
        }
    }
    
    /// Deletes the CoreData entry for the current track (including userPicked and
    /// none_found entries) and resets in-memory state so the next tick re-runs
    /// the full lyric-fetch chain from scratch.
    func resetLyricsForCurrentTrack() {
        guard let trackID = currentlyPlaying else { return }
        // Run asynchronously so the menubar-button click handler returns immediately
        // and the main thread isn't blocked by CoreData I/O or the ScriptingBridge
        // calls inside setCurrentPropertiesPublic(). All work still runs on
        // @MainActor (required for viewContext), but yields the call stack first.
        Task { @MainActor in
            let ctx = coreDataContainer.viewContext
            let request: NSFetchRequest<SongObject> = SongObject.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", trackID)
            if let existing = try? ctx.fetch(request).first {
                ctx.delete(existing)
                saveCoreData()
            }
            // Reset in-memory state; the next player-change tick will re-fetch.
            currentlyPlayingLyrics = []
            currentFetchTask?.cancel()
            // Yield once so the cancelled task can observe its cancellation before
            // setCurrentPropertiesPublic() spawns a new fetch chain.
            await Task.yield()
            setCurrentPropertiesPublic()
        }
    }

    func fetchFromCoreData(for trackID: String) -> [LyricLine]? {
        let fetchRequest: NSFetchRequest<SongObject> = SongObject.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", trackID) // Replace trackID with the desired value

        do {
            let results = try coreDataContainer.viewContext.fetch(fetchRequest)
            if let songObject = results.first {
                // Found the SongObject with the matching trackID
                let lyricsArray = zip(songObject.lyricsTimestamps, songObject.lyricsWords).map { LyricLine(startTime: $0, words: $1) }
                print("Found SongObject with ID:", songObject.id)
                return lyricsArray
            } else {
                // No SongObject found with the given trackID
                print("No SongObject found with the provided trackID. \(trackID)")
            }
        } catch {
            print("Error fetching SongObject:", error)
        }
        return nil
    }
    
    #if os(macOS)
    func reloadTranslationConfigIfTranslating() -> Bool {
        // Server-side translation ALWAYS wins when available, regardless of
        // the user's `translate` toggle. The toggle only gates the local
        // Apple Translation fallback. Reason: the cfprefsd cache on
        // sandboxed builds can hold stale `translate=false` even after we
        // flipped the default; insisting on the toggle would leave users
        // staring at an empty translation tier with no obvious way to fix it.
        if let serverTrn = lastNetworkResult?.translation,
           !serverTrn.isEmpty,
           serverTrn.count == currentlyPlayingLyrics.count {
            print("Translated Lyrics from Lyrics9x server enrichment (\(serverTrn.count) lines)")
            translatedLyric = serverTrn
            return false
        }
        if userDefaultStorage.translate {
            if translationSessionConfig == TranslationSession.Configuration(source: translationSourceLanguage, target: userLocaleLanguage) {
                translationSessionConfig?.invalidate()
            } else {
                translationSessionConfig = TranslationSession.Configuration(source: translationSourceLanguage, target: userLocaleLanguage)
            }
            return true
        } else {
            return false
        }
    }
    #endif
    
    func fetchTranslationSourceLanguage() {
        guard let currentlyPlaying else {
            print("Translation: ignoring translationSourceLang fetch due to nil currentlyPlaying")
            return
        }
        let fetchRequest: NSFetchRequest<SongToLocale> = SongToLocale.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", currentlyPlaying) // Replace trackID with the desired value

        do {
            let results = try coreDataContainer.viewContext.fetch(fetchRequest)
            if let songToLocale = results.first?.locale {
                self.translationSourceLanguage = Locale.Language(identifier: songToLocale)
            } else {
                self.translationSourceLanguage = nil
            }
        } catch {
            print("Error fetching translationSourceLanguage:", error)
        }
    }
    
    #if os(macOS)
    func setNewLyricsColorTranslationRomanizationAndStartUpdater(with newLyrics: [LyricLine]) {
        currentlyPlayingLyrics = newLyrics
        // Reset the end-of-track preload guard whenever a new track's lyrics
        // load — so the upcoming-track preload fires once per track.
        endOfTrackPreloadedFor = nil
        startEndOfTrackPreloader()
        setBackgroundColor()
        fetchTranslationSourceLanguage()
        let _ = reloadTranslationConfigIfTranslating()
//        romanizeDidChange()
        chinesePreferenceDidChange()
        // we romanize afterwards, in-case the chinese conversion array was populated
        romanizeDidChange()
        lyricsIsEmptyPostLoad = currentlyPlayingLyrics.isEmpty
        if isPlaying, !currentlyPlayingLyrics.isEmpty, showLyrics, userDefaultStorage.hasOnboarded {
            startLyricUpdater()
        }
    }
    
    @MainActor
    func uploadLocalLRCFile() async throws {
        guard let currentlyPlaying = currentlyPlaying, let currentlyPlayingName = currentlyPlayingName else {
            throw CancellationError()
        }
        let duration = self.duration
        let localLyrics = try await localFileUploadProvider.localFetch(for: currentlyPlaying, currentlyPlayingName)
        let cleanLyrics = NetworkFetchReturn(lyrics: localLyrics, colorData: nil).processed(withSongName: currentlyPlayingName, duration: duration).lyrics
        if self.currentlyPlaying == currentlyPlaying {
            setNewLyricsColorTranslationRomanizationAndStartUpdater(with: cleanLyrics)
        }
        
        // thats how i save to coredata
        let _ = SongObject(from: cleanLyrics, with: coreDataContainer.viewContext, trackID: currentlyPlaying, trackName: currentlyPlayingName)
        saveCoreData()
    }
    #endif
    
    func stepsToTakeAfterSettingsLyrics() async {
        
    }
    
    func didOnboard() {
        guard isPlayerRunning else {
            isPlaying = false
            currentlyPlaying = nil
            currentlyPlayingName = nil
            currentlyPlayingArtist = nil
            #if os(macOS)
            currentlyPlayingAppleMusicPersistentID = nil
            #endif
            return
        }
        print("Application just started (finished onboarding). lets check whats playing")
        if currentPlayerInstance.isPlaying {
            isPlaying = true
        }
        setCurrentProperties()
        startLyricUpdater()
    }
}

#if os(macOS)
// Apple Music Code
extension ViewModel {
    // Similar structure to my other Async functions. Only 1 appleMusic) can run at any given moment
    func appleMusicStarter() async {
        print("apple music test called again, cancelling previous")
        currentAppleMusicFetchTask?.cancel()
        let newFetchTask = Task {
            try await self.appleMusicFetch()
        }
        currentAppleMusicFetchTask = newFetchTask
        do {
            return try await newFetchTask.value
        } catch {
            print("error \(error)")
            return
        }
    }
    
    func appleMusicFetch() async throws {
        // check coredata for apple music persistent id -> spotify id mapping
        if let coreDataSpotifyID = fetchSpotifyIDFromPersistentIDCoreData() {
            if !Task.isCancelled {
                print("Apple Music CoreData Fetch: setting currentlyPlaying to \(coreDataSpotifyID)")
                self.currentlyPlaying = coreDataSpotifyID
                return
            }
        }
        print("Apple Music Fetch: No CoreData val. Fetching from network")
        try await appleMusicNetworkFetch()
    }
    
    func appleMusicNetworkFetch() async throws {
        isFetching = true
//        do {
//            print("Apple Music Network Fetch: 3 second sleep")
//            try await Task.sleep(for: .seconds(3))
//        } catch {
//            print("Apple Music Network Fetch cancelled during the 3 seconds of sleep")
//        }
        print("Apple Music Network Fetch: isFetching set to true")
        // coredata didn't get us anything
//        try await spotifyLyricProvider.generateAccessToken()
        
        // Task cancelled means we're working with old song data, so dont update Spotify ID with old song's ID
        
        // search for equivalent spotify song
        if let spotifyResult = try await musicToSpotifyHelper() {
            self.currentlyPlayingName = spotifyResult.SpotifyName
            self.currentlyPlayingArtist = spotifyResult.SpotifyArtist
            self.currentAlbumName = spotifyResult.SpotifyAlbum
            self.currentlyPlaying = spotifyResult.SpotifyID
        } else {
            if let alternativeID = appleMusicPlayer.alternativeID, alternativeID != "" {
                try Task.checkCancellation()
                self.currentlyPlaying = alternativeID
            } else {
                lyricsIsEmptyPostLoad = true
            }
        }
        
        
        if let currentlyPlayingAppleMusicPersistentID, let currentlyPlaying {
            print("Apple Music Network Fetch: Saving persistent id \(currentlyPlayingAppleMusicPersistentID) and spotify ID \(currentlyPlaying)")
            // save the mapping into coredata persistentIDToSpotify
            let newPersistentIDToSpotifyIDMapping = PersistentIDToSpotify(context: coreDataContainer.viewContext)
            newPersistentIDToSpotifyIDMapping.persistentID = currentlyPlayingAppleMusicPersistentID
            newPersistentIDToSpotifyIDMapping.spotifyID = currentlyPlaying
            saveCoreData()
        }
    }
    
    func fetchSpotifyIDFromPersistentIDCoreData() -> String? {
        let fetchRequest: NSFetchRequest<PersistentIDToSpotify> = PersistentIDToSpotify.fetchRequest()
        guard let currentlyPlayingAppleMusicPersistentID else {
            print("No persistent ID available. it's nil! should have never happened")
            return nil
        }
        fetchRequest.predicate = NSPredicate(format: "persistentID == %@", currentlyPlayingAppleMusicPersistentID) // Replace persistentID with the desired value

        do {
            let results = try coreDataContainer.viewContext.fetch(fetchRequest)
            if let persistentIDToSpotify = results.first {
                // Found the persistentIDToSpotify object with the matching persistentID
                print("Apple Music CoreData Fetch: Found SpotifyID \(persistentIDToSpotify.spotifyID) for \(persistentIDToSpotify.persistentID)")
                return persistentIDToSpotify.spotifyID
            } else {
                // No SongObject found with the given trackID
                print("No spotifyID found with the provided persistentID. \(currentlyPlayingAppleMusicPersistentID)")
            }
        } catch {
            print("Error fetching persistentIDToSpotify:", error)
        }
        return nil
    }
    
    private func musicToSpotifyHelper() async throws -> AppleMusicHelper? {
        // Manually search song name, artist name
        guard let currentlyPlayingArtist, let currentlyPlayingName else {
            print("\(#function) currentlyPlayingName or currentlyPlayingArtist missing")
            return nil
        }
        return try await spotifyLyricProvider.searchForTrackForAppleMusic(artist: currentlyPlayingArtist, track: currentlyPlayingName)
    }
}
#endif


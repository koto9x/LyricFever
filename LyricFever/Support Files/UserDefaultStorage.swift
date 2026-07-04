//
//  UserDefaultStorage.swift
//  Lyric Fever
//
//  Created by Avi Wadhwa on 2025-07-17.
//

import Combine
import SwiftUI
//import ObservableDefaults
import ObservableUserDefault


//@ObservableDefaults
@Observable
class UserDefaultStorage {
    @ObservableUserDefault(.init(key: "translate", defaultValue: true, store: .standard))
    @ObservationIgnored var translate: Bool
    @ObservableUserDefault(.init(key: "translationTargetLanguage", store: .standard))
    @ObservationIgnored var translationTargetLanguage: Locale.Language?
//    var furigana = false
    #if os(macOS)
    @ObservableUserDefault(.init(key: "showSongDetailsInMenubar", defaultValue: false, store: .standard))
    @ObservationIgnored var showSongDetailsInMenubar: Bool
    #endif
    @ObservableUserDefault(.init(key: "blurFullscreen", defaultValue: true, store: .standard))
    @ObservationIgnored var blurFullscreen: Bool
    @ObservableUserDefault(.init(key: "animateOnStartupFullscreen", defaultValue: true, store: .standard))
    @ObservationIgnored var animateOnStartupFullscreen: Bool
    #if os(macOS)
    // When true, the fullscreen window is a movable/resizable borderless window
    // on the current Space instead of macOS native fullscreen (which swipes to a
    // new Space and hides the menubar/Dock).
    @ObservableUserDefault(.init(key: "useWindowedFullscreen", defaultValue: true, store: .standard))
    @ObservationIgnored var useWindowedFullscreen: Bool
    #endif
    @ObservableUserDefault(.init(key: "romanize", defaultValue: true, store: .standard))
    @ObservationIgnored var romanize: Bool
    @ObservableUserDefault(.init(key: "romanizeMetadata", defaultValue: true, store: .standard))
    @ObservationIgnored var romanizeMetadata: Bool
    @ObservableUserDefault(.init(key: "chinesePreference", defaultValue: 0, store: .standard))
    @ObservationIgnored var chinesePreference: Int
    #if os(macOS)
    @ObservableUserDefault(.init(key: "spotifyConnectDelayCount", defaultValue: 400, store: .standard))
    @ObservationIgnored var spotifyConnectDelayCount: Int
    @ObservableUserDefault(.init(key: "hasMigrated", defaultValue: false, store: .standard))
    @ObservationIgnored var hasMigrated: Bool
    
    // User setting: use album art color or user-set currentBackground
    @ObservableUserDefault(.init(key: "karaoke", defaultValue: true, store: .standard))
    @ObservationIgnored var karaoke: Bool
//    var karaokeUseAlbumColor: Bool = true
    @ObservableUserDefault(.init(key: "karaokeShowMultilingual", defaultValue: true, store: .standard))
    @ObservationIgnored var karaokeShowMultilingual: Bool
    @ObservableUserDefault(.init(key: "karaokeTransparency", defaultValue: 50, store: .standard))
    @ObservationIgnored var karaokeTransparency: Double
//    var fixedKaraokeColorHex: String = "#2D3CCC"
    
    // User setting: hide karaoke on hover
    @ObservableUserDefault(.init(key: "karaokeModeHoveringSetting", defaultValue: false, store: .standard))
    @ObservationIgnored var karaokeModeHoveringSetting: Bool
    #endif

//    @DefaultsKey(userDefaultsKey: "spDcCookie")
    @ObservableUserDefault(.init(key: "spDcCookie", defaultValue: "", store: .standard))
    @ObservationIgnored var cookie: String
    
    #if os(macOS)
    // False: Spotify, True: Apple Music
    @ObservableUserDefault(.init(key: "spotifyOrAppleMusic", defaultValue: false, store: .standard))
    @ObservationIgnored var spotifyOrAppleMusic: Bool
    // When true, override spotifyOrAppleMusic and route via Plexamp. Talks to Plexamp's
    // local HTTP control API on port 32500 plus reads ~/Library/Application Support/Plexamp/PlayQueue.json
    // for track metadata; lyrics resolve via Koto's self-hosted lyrics.9x.studio /api/get endpoint.
    @ObservableUserDefault(.init(key: "usePlexamp", defaultValue: true, store: .standard))
    @ObservationIgnored var usePlexamp: Bool
    // When true, takes priority over usePlexamp/spotifyOrAppleMusic: watches
    // Music Assistant's queues over its push WebSocket instead of tracking
    // Plexamp/Apple Music/Spotify individually. MA already aggregates those
    // (plus YouTube Music, NTS Radio) into one hub, so this is meant to
    // eventually replace the per-app "smart routing" dance below it.
    @ObservableUserDefault(.init(key: "useMusicAssistant", defaultValue: false, store: .standard))
    @ObservationIgnored var useMusicAssistant: Bool
    // host:port, no scheme. Defaults to kaiosmini's Tailscale IP (same one
    // Lyrics9x already uses) so the existing ATS exception domain covers it
    // without needing a second Info.plist entry.
    @ObservableUserDefault(.init(key: "musicAssistantHost", defaultValue: "100.114.244.6:8095", store: .standard))
    @ObservationIgnored var musicAssistantHost: String
    @ObservableUserDefault(.init(key: "musicAssistantToken", defaultValue: "", store: .standard))
    @ObservationIgnored var musicAssistantToken: String
    @ObservableUserDefault(.init(key: "latestUpdateWindowShown", defaultValue: 0, store: .standard))
    @ObservationIgnored var latestUpdateWindowShown: Int
    #endif
    @ObservableUserDefault(.init(key: "hasOnboarded", defaultValue: false, store: .standard))
    @ObservationIgnored var hasOnboarded: Bool
    @ObservableUserDefault(.init(key: "hasTranslated", defaultValue: false, store: .standard))
    @ObservationIgnored var hasTranslated: Bool
    @ObservableUserDefault(.init(key: "truncationLength", defaultValue: 40, store: .standard))
    @ObservationIgnored var truncationLength: Int
}

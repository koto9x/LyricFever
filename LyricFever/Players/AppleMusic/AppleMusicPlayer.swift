//
//  AppleMusicPlayer.swift
//  Lyric Fever
//
//  Created by Avi Wadhwa on 2025-07-18.
//

import ScriptingBridge
import MusicKit
import AppKit

class AppleMusicPlayer: Player {
    var appleMusicScript: MusicApplication? = SBApplication(bundleIdentifier: "com.apple.Music")
    var persistentID: String? {
        appleMusicScript?.currentTrack?.persistentID
    }
    var alternativeID: String? {
        let baseID = (appleMusicScript?.currentTrack?.artist ?? "") + (appleMusicScript?.currentTrack?.name ?? "")
        return baseID.count == 22 ? baseID + "_" : baseID
    }
    
    var albumName: String? {
        appleMusicScript?.currentTrack?.album
    }
    var artistName: String? {
        appleMusicScript?.currentTrack?.artist
    }
    var trackName: String? {
        appleMusicScript?.currentTrack?.name
    }
    
    @MainActor
    var currentTime: TimeInterval? {
        guard let playerPosition = appleMusicScript?.playerPosition else {
            return nil
        }
        let viewmodel = ViewModel.shared
        return playerPosition * 1000 + 400 + (viewmodel.animatedDisplay ? 400 : 0) + (viewmodel.airplayDelay ?  -2000 : 0)
    }
    var duration: Int? {
        guard let seconds = appleMusicScript?.currentTrack?.duration.map(Int.init) else {
            print("Apple Music Player: Couldn't fetch duration")
            return nil
        }
        return seconds * 1000
    }
    
    var isAuthorized: Bool {
        guard isRunning else {
            return false
        }
        if appleMusicScript?.playerState?.rawValue == 0 {
            return false
        }
        return true
    }
    var isPlaying: Bool {
        appleMusicScript?.playerState == .playing
    }
    var isRunning: Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil {
            return true
        } else {
            return false
        }
    }
    
    var volume: Int {
        appleMusicScript?.soundVolume ?? 0
    }
    
    func decreaseVolume() {
        guard let soundVolume = appleMusicScript?.soundVolume else {
            return
        }
        appleMusicScript?.setSoundVolume?(soundVolume-5)
    }
    func increaseVolume() {
        guard let soundVolume = appleMusicScript?.soundVolume else {
            return
        }
        appleMusicScript?.setSoundVolume?(soundVolume+5)
    }
    func setVolume(to newVolume: Double) {
        appleMusicScript?.setSoundVolume?(Int(newVolume))
    }
    func togglePlayback() {
        appleMusicScript?.playpause?()
    }
    func rewind() {
        appleMusicScript?.previousTrack?()
    }
    func forward() {
        appleMusicScript?.nextTrack?()
    }
    func seek(toMillis millis: Int) {
        // Music.app's playerPosition is a Double in seconds.
        appleMusicScript?.setPlayerPosition?(Double(millis) / 1000.0)
    }
    
    /// Most recently observed Apple Music catalog ID (Adam ID), sourced from
    /// MediaRemote's now-playing payload. Nil for tracks not in the catalog
    /// (imported MP3s, audiobooks, etc).
    var lastObservedCatalogID: String?

    /// Most recently observed album catalog ID. Nil if the payload didn't
    /// surface one or the album isn't in the catalog.
    var lastObservedAlbumCatalogID: String?

    var artworkImage: NSImage?

//    var artworkImage: NSImage? {
//        guard let artworkImage = (appleMusicScript?.currentTrack?.artworks?().firstObject as? MusicArtwork)?.data else {
//            print("AppleMusicPlayer artworkImage: nil data")
//            return nil
//        }
//        return artworkImage
//    }
    
    func activate() {
        appleMusicScript?.activate()
    }
    var currentHoverItem: MenubarButtonHighlight = .activateAppleMusic

    /// Best-effort enumeration of the next N tracks in Music.app's current playlist
    /// queue. Returns Apple Music catalog IDs only (skips local-library / non-catalog
    /// tracks). Returns nil if Music.app isn't running, the queue is empty, or no
    /// catalog IDs are obtainable from AppleScript (the common v1 case).
    func upcomingQueueCatalogIDs(limit: Int) -> [String]? {
        // Music.app's AppleScript dictionary doesn't expose per-track Adam IDs
        // for catalog tracks. The catalog ID flows in only via MediaRemote, which
        // we only get for the CURRENTLY playing track — not upcoming ones.
        //
        // For v1, return nil (no-op). The warmAlbum path covers the common case
        // (sequential album playback). A future extension could:
        //  1) Read the current playlist's tracks via SBElementArray
        //  2) For each upcoming track, attempt to map its persistentID/databaseID
        //     to a catalog Adam ID via MusicKit's MusicLibraryRequest
        //  3) Filter to only those that successfully resolve
        return nil
    }
}

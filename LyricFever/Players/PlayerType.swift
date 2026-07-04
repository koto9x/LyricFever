//
//  Untitled.swift
//  Lyric Fever
//
//  Created by Avi Wadhwa on 2025-07-17.
//

enum PlayerType: CustomStringConvertible, CaseIterable, Identifiable {
    var id: Self { self }

    var description: String {
        switch self {
            case .spotify:
                return "Spotify"
            case .appleMusic:
                return "Apple Music"
            case .plexamp:
                return "Plexamp"
            case .musicAssistant:
                return "Music Assistant"
        }
    }

    var imageName: String {
        switch self {
            case .spotify:
                return "spotify"
            case .appleMusic:
                return "music"
            case .plexamp:
                return "music.note.house"
            case .musicAssistant:
                return "hifispeaker.2"
        }
    }
    case spotify
    case appleMusic
    case plexamp
    case musicAssistant
}

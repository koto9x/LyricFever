//
//  NetworkFetchReturn.swift
//  Lyric Fever
//
//  Created by Avi Wadhwa on 2025-08-06.
//

struct NetworkFetchReturn {
    let lyrics: [LyricLine]
    let colorData: Int32?
    // Aligned to `lyrics` by index. Both default to nil so existing providers
    // don't need updating; Lyrics9xLyricProvider populates them when the
    // kaiosmini /api/lookup response includes server-side romanization and
    // translation streams (3-tier learning display).
    let romanization: [String]?
    let translation: [String]?
    let language: String?

    init(lyrics: [LyricLine], colorData: Int32?, romanization: [String]? = nil, translation: [String]? = nil, language: String? = nil) {
        self.lyrics = lyrics
        self.colorData = colorData
        self.romanization = romanization
        self.translation = translation
        self.language = language
    }

    func processed(withSongName songName: String, duration: Int) -> NetworkFetchReturn {
        let filtered = lyrics.filter { !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard lyrics.count > 1 else {
            print("FetchLyrics NetworkFetchReturn: count is less than 2. returning myself")
            return self
        }

        let nowPlayingLine = LyricLine(startTime: Double(duration + 5000), words: "Now Playing: \(songName)")
        return NetworkFetchReturn(lyrics: filtered + [nowPlayingLine], colorData: colorData, romanization: romanization, translation: translation, language: language)
    }
}


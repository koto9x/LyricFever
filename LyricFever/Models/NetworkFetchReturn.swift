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
    /// The source knows this track has no lyrics BY DESIGN (instrumental) —
    /// distinct from "none found", it should stick and stop the chain.
    let instrumental: Bool

    init(lyrics: [LyricLine], colorData: Int32?, romanization: [String]? = nil, translation: [String]? = nil, language: String? = nil, instrumental: Bool = false) {
        self.lyrics = lyrics
        self.colorData = colorData
        self.romanization = romanization
        self.translation = translation
        self.language = language
        self.instrumental = instrumental
    }

    func processed(withSongName songName: String, duration: Int) -> NetworkFetchReturn {
        guard lyrics.count > 1 else {
            print("FetchLyrics NetworkFetchReturn: count is less than 2. returning myself")
            return self
        }

        // Filter empty lines while keeping romanization + translation arrays
        // aligned to the post-filter lyrics array. Without this, ViewModel's
        // server-data alignment check (`serverTrn.count == currentlyPlayingLyrics.count`)
        // fails and the chain falls through to Mecab + Apple Translation
        // even when the server provided both layers.
        var filteredLyrics: [LyricLine] = []
        var filteredRoman: [String] = []
        var filteredTrans: [String] = []
        for (i, line) in lyrics.enumerated() {
            if line.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            filteredLyrics.append(line)
            if let rom = romanization, i < rom.count { filteredRoman.append(rom[i]) }
            if let trn = translation, i < trn.count { filteredTrans.append(trn[i]) }
        }

        let nowPlayingLine = LyricLine(startTime: Double(duration + 5000), words: "Now Playing: \(songName)")
        filteredLyrics.append(nowPlayingLine)
        // Now-Playing line has no enrichment counterpart — pad both arrays with
        // empty strings to keep the count match.
        if !filteredRoman.isEmpty { filteredRoman.append("") }
        if !filteredTrans.isEmpty { filteredTrans.append("") }

        return NetworkFetchReturn(
            lyrics: filteredLyrics,
            colorData: colorData,
            romanization: filteredRoman.isEmpty ? nil : filteredRoman,
            translation: filteredTrans.isEmpty ? nil : filteredTrans,
            language: language,
            instrumental: instrumental
        )
    }
}


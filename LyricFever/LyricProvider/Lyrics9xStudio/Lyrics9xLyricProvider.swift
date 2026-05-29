//
//  Lyrics9xLyricProvider.swift
//  Lyric Fever
//
//  Talks to Koto's self-hosted lyric service at https://lyrics.9x.studio/api/get,
//  which serves .lrc sidecars from the kaiosmini-side lyric-fetch library indexed
//  by track tag metadata (artist + title, optional album). Used as the primary
//  lyric source when the current player is Plexamp; falls back to LRCLIB on miss.
//

import Foundation

class Lyrics9xLyricProvider: LyricProvider {
    var providerName = "Lyrics 9x Studio Provider"

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        cfg.httpAdditionalHeaders = ["User-Agent": "Lyric Fever (Plexamp integration) — koto9x"]
        return URLSession(configuration: cfg)
    }()

    private struct LyricsResponse: Decodable {
        let lyrics: String
    }

    @MainActor
    func fetchNetworkLyrics(trackName: String, trackID: String, currentlyPlayingArtist: String?, currentAlbumName: String?) async throws -> NetworkFetchReturn {
        guard let artist = currentlyPlayingArtist, !artist.isEmpty else {
            print("Lyrics9x: missing artist; skipping")
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: trackName),
        ]
        if let album = currentAlbumName, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "lyrics.9x.studio"
        comps.path = "/api/get"
        comps.queryItems = items
        guard let url = comps.url else {
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        print("Lyrics9x /api/get: \(url.absoluteString)")
        let (data, response) = try await urlSession.data(for: URLRequest(url: url))
        // 404 == not in the self-hosted library; let the chain fall through to LRCLIB.
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            print("Lyrics9x: 404 — track not in self-hosted library")
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        let decoded = try JSONDecoder().decode(LyricsResponse.self, from: data)
        let lines = LRCLIBLyrics.decodeLyrics(input: decoded.lyrics)
        return NetworkFetchReturn(lyrics: lines, colorData: nil)
    }

    @MainActor
    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        // No /api/search on lyric-fetch — the dashboard does fuzzy matching in JS but isn't
        // exposed as JSON. Mass-search falls back to LRCLIB; this provider only powers the
        // direct now-playing lookup.
        return []
    }
}

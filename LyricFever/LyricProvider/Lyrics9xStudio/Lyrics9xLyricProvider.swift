//
//  Lyrics9xLyricProvider.swift
//  Lyric Fever
//
//  Talks to Koto's self-hosted lyric service on kaiosmini via the Tailscale IP
//  (bypasses the public Caddy in front of lyrics.9x.studio, which has a 30s
//  proxy timeout that strangles cold syncedlyrics calls). The endpoint cascades:
//    library tag-index → on-disk cache → live syncedlyrics (LRCLIB / Musixmatch /
//    NetEase / Genius), with successful live results written back to the cache.
//  This means niche artists not in the local Plex library are discovered + cached
//  on first play, then served instantly forever after.
//

import Foundation

class Lyrics9xLyricProvider: LyricProvider {
    var providerName = "Lyrics 9x Studio Provider"

    // Tailscale IP for kaiosmini. Works from any device on the Tailnet (asgard16,
    // k13, kaiosmini itself, future fleet). Bypasses the public lyrics.9x.studio
    // Caddy front so cold syncedlyrics calls aren't proxy-timed-out at 30s.
    private static let baseURL = "http://100.114.244.6:8676"

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        // syncedlyrics cold lookups can take 10-30s (4 providers in series).
        // Generous request timeout; resource timeout slightly higher to absorb
        // edge cases without ever hanging Lyric Fever's UI forever.
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["User-Agent": "Lyric Fever (Plexamp integration) — koto9x"]
        return URLSession(configuration: cfg)
    }()

    private struct LyricsResponse: Decodable {
        let lyrics: String
        let source: String?
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
        guard var comps = URLComponents(string: Self.baseURL) else {
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        comps.path = "/api/lookup"
        comps.queryItems = items
        guard let url = comps.url else {
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        print("Lyrics9x /api/lookup: \(url.absoluteString)")
        let (data, response) = try await urlSession.data(for: URLRequest(url: url))
        // 404 == not in library, not in cache, and syncedlyrics couldn't find it
        // anywhere. Let the chain fall through to LRCLIB / NetEase / Spotify.
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            print("Lyrics9x: 404 — not found in library, cache, or any syncedlyrics provider")
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        let decoded = try JSONDecoder().decode(LyricsResponse.self, from: data)
        if decoded.lyrics.isEmpty {
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        let lines = LRCLIBLyrics.decodeLyrics(input: decoded.lyrics)
        print("Lyrics9x: hit via source=\(decoded.source ?? "unknown"), \(lines.count) lines")
        return NetworkFetchReturn(lyrics: lines, colorData: nil)
    }

    @MainActor
    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        // No mass-search endpoint exposed; lyric-fetch dashboard does fuzzy matching
        // in JS but isn't published as JSON. This provider only powers the direct
        // now-playing lookup. Mass-search falls back through the rest of the chain.
        return []
    }
}

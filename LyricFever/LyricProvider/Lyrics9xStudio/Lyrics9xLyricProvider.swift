//
//  Lyrics9xLyricProvider.swift
//  Lyric Fever
//
//  Talks to kaiosmini's lyric-fetch service via Tailscale. The `/api/lookup`
//  endpoint cascades library → on-disk cache → live syncedlyrics, and for
//  foreign-language tracks also returns server-side romanization + English
//  translation streams (cached as JSON alongside the raw .lrc). This provider
//  decodes all three streams and aligns them by timestamp so the FullscreenView
//  can render a 3-tier display (original → romanization → translation).
//

import Foundation

class Lyrics9xLyricProvider: LyricProvider {
    var providerName = "Lyrics 9x Studio Provider"

    private static let baseURL = "http://100.114.244.6:8676"

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Cold lookups can take 10-30s (syncedlyrics across 4 providers + then
        // translation via deep-translator). Generous timeouts; the chain only
        // hits Lyrics9x first so other providers absorb the wait too.
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["User-Agent": "Lyric Fever (Plexamp integration) — koto9x"]
        return URLSession(configuration: cfg)
    }()

    private struct LookupResponse: Decodable {
        let lyrics: String
        let romanization: String?
        let translation: String?
        let language: String?
        let source: String?
    }

    /// Parse a server-returned LRC stream into a timestamp→text map keyed by
    /// the original startTime (in ms, matching `LyricLine.startTime`). Used
    /// for safe per-line alignment when the server returns fewer lines than
    /// the main lyrics stream (e.g. metadata-only lines may be skipped).
    private static func indexLRCByTimestamp(_ lrcText: String) -> [Double: String] {
        var map: [Double: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"\[(\d{2}:\d{2}\.\d{1,3})\]\s*(.*)"#)
        for raw in lrcText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            for m in matches {
                if let tsRange = Range(m.range(at: 1), in: line),
                   let txtRange = Range(m.range(at: 2), in: line) {
                    let startTime = String(line[tsRange]).convertToTimeInterval()
                    map[startTime] = String(line[txtRange])
                }
            }
        }
        return map
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
        // Track length lets the server synthesize sanely-paced timestamps for
        // plain (unsynced) lyrics — e.g. Genius-only niche artists — so they
        // still render in our LRC-driven UI.
        let durationMs = ViewModel.shared.duration
        if durationMs > 0 {
            items.append(URLQueryItem(name: "duration", value: String(durationMs / 1000)))
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
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            print("Lyrics9x: 404 — not in library, cache, or any syncedlyrics provider")
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        if decoded.lyrics.isEmpty {
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
        let lines = LRCLIBLyrics.decodeLyrics(input: decoded.lyrics)

        // Build per-line aligned romanization + translation arrays. Server
        // streams use the same timestamps as the original so we can look up
        // each line by startTime; missing entries fall back to empty so the
        // FullscreenView can skip rendering that tier for that line.
        var romanArr: [String]? = nil
        var translateArr: [String]? = nil
        if let rom = decoded.romanization, !rom.isEmpty {
            let map = Self.indexLRCByTimestamp(rom)
            romanArr = lines.map { map[$0.startTimeMS] ?? "" }
        }
        if let trn = decoded.translation, !trn.isEmpty {
            let map = Self.indexLRCByTimestamp(trn)
            translateArr = lines.map { map[$0.startTimeMS] ?? "" }
        }

        print("Lyrics9x: hit via source=\(decoded.source ?? "unknown") language=\(decoded.language ?? "unknown") lines=\(lines.count) rom=\(romanArr?.count ?? 0) trn=\(translateArr?.count ?? 0)")
        return NetworkFetchReturn(
            lyrics: lines,
            colorData: nil,
            romanization: romanArr,
            translation: translateArr,
            language: decoded.language
        )
    }

    @MainActor
    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        return []
    }

    /// Enrichment-only mode for the case where lyrics were already loaded
    /// (typically from CoreData cache) and we need just romanization +
    /// translation aligned to the existing `[LyricLine]`. Same HTTP call as
    /// `fetchNetworkLyrics`, but instead of producing a new LyricLine array
    /// we look up each existing line's `startTimeMS` against the server's
    /// per-line maps. Lines the server didn't enrich come back as "".
    @MainActor
    func fetchEnrichmentOnly(trackName: String, artist: String?, album: String?, existingLyrics: [LyricLine]) async throws -> (romanization: [String]?, translation: [String]?, language: String?) {
        guard let artist, !artist.isEmpty, !existingLyrics.isEmpty else { return (nil, nil, nil) }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: trackName),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        guard var comps = URLComponents(string: Self.baseURL) else { return (nil, nil, nil) }
        comps.path = "/api/lookup"
        comps.queryItems = items
        guard let url = comps.url else { return (nil, nil, nil) }
        print("Lyrics9x /api/lookup (enrichment-only): \(url.absoluteString)")
        let (data, response) = try await urlSession.data(for: URLRequest(url: url))
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return (nil, nil, nil)
        }
        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        var romanArr: [String]? = nil
        var translateArr: [String]? = nil
        if let rom = decoded.romanization, !rom.isEmpty {
            let map = Self.indexLRCByTimestamp(rom)
            romanArr = existingLyrics.map { map[$0.startTimeMS] ?? "" }
        }
        if let trn = decoded.translation, !trn.isEmpty {
            let map = Self.indexLRCByTimestamp(trn)
            translateArr = existingLyrics.map { map[$0.startTimeMS] ?? "" }
        }
        print("Lyrics9x enrichment-only: language=\(decoded.language ?? "?") rom=\(romanArr?.count ?? 0) trn=\(translateArr?.count ?? 0) for \(existingLyrics.count) lines")
        return (romanArr, translateArr, decoded.language)
    }
}

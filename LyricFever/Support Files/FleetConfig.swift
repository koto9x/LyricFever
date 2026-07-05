//
//  FleetConfig.swift
//  Lyric Fever
//
//  Koto-only fleet auth sync (NOT for upstream PRs). Pulls shared secrets
//  (Spotify sp_dc cookie, Music Assistant token, onboarding bootstrap) from
//  kaiosmini's lyric-fetch /api/config on every launch, and pushes a freshly
//  validated cookie after login — one Spotify login anywhere covers the
//  whole fleet. Everything is best-effort: kaiosmini being unreachable must
//  leave the app behaving exactly as before this feature existed.
//  Spec: docs/superpowers/specs/2026-07-05-fleet-auth-sync-design.md
//

import Foundation

class FleetConfig {
    static let shared = FleetConfig()

    // Same host Lyrics9x + MA already use, covered by the scoped ATS exception.
    private static let configURL = URL(string: "http://100.114.244.6:8676/api/config")!
    private static let pendingPushKey = "fleetConfigPendingPush"

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    /// Launch-time sync. Never throws, never blocks anything that matters.
    func pullAndApply() async {
        guard let config = await fetchConfig() else {
            print("FleetConfig: pull skipped (kaiosmini unreachable)")
            return
        }
        let defaults = UserDefaults.standard
        let local = await MainActor.run { ViewModel.shared.userDefaultStorage.cookie }
        let action = decideFleetCookieAction(
            local: local,
            server: config["spDcCookie"] as? String,
            pendingPush: defaults.bool(forKey: Self.pendingPushKey)
        )
        switch action {
        case .adoptServer(let serverCookie):
            await MainActor.run {
                ViewModel.shared.userDefaultStorage.cookie = serverCookie
                // init() force-resets hasOnboarded when the cookie is empty;
                // a real cookie is exactly what onboarding establishes.
                ViewModel.shared.userDefaultStorage.hasOnboarded = true
            }
            print("FleetConfig: adopted server cookie (length \(serverCookie.count))")
        case .pushLocal:
            print("FleetConfig: pending local cookie, pushing instead of adopting")
            await push(cookie: local)
        case .none:
            break
        }
        // Bootstrap values: fill only when locally empty/unset so per-machine
        // overrides survive.
        await MainActor.run {
            let storage = ViewModel.shared.userDefaultStorage
            if storage.musicAssistantToken.isEmpty, let t = config["musicAssistantToken"] as? String, !t.isEmpty {
                storage.musicAssistantToken = t
                print("FleetConfig: filled musicAssistantToken (length \(t.count))")
            }
            if defaults.object(forKey: "musicAssistantHost") == nil, let h = config["musicAssistantHost"] as? String, !h.isEmpty {
                storage.musicAssistantHost = h
            }
            if defaults.object(forKey: "useMusicAssistant") == nil, let u = config["useMusicAssistant"] as? Bool {
                storage.useMusicAssistant = u
            }
            if defaults.object(forKey: "hasOnboarded") == nil, let o = config["hasOnboarded"] as? Bool {
                storage.hasOnboarded = o
            }
        }
    }

    /// Push a freshly validated cookie so the rest of the fleet picks it up.
    /// On failure, mark it pending so the next launch pushes instead of
    /// letting server-wins clobber the only fresh copy.
    func push(cookie: String) async {
        guard !cookie.isEmpty else { return }
        var request = URLRequest(url: Self.configURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["spDcCookie": cookie])
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            UserDefaults.standard.removeObject(forKey: Self.pendingPushKey)
            print("FleetConfig: pushed cookie (length \(cookie.count))")
        } catch {
            UserDefaults.standard.set(true, forKey: Self.pendingPushKey)
            print("FleetConfig: push failed, marked pending — \(error.localizedDescription)")
        }
    }

    private func fetchConfig() async -> [String: Any]? {
        do {
            let (data, response) = try await urlSession.data(from: Self.configURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}

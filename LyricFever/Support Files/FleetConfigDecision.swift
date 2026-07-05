//
//  FleetConfigDecision.swift
//  Lyric Fever
//
//  Koto-only fleet auth sync (NOT for upstream PRs) — pure decision logic
//  for what to do with the Spotify sp_dc cookie on launch, given the local
//  copy, the server (kaiosmini fleet-config) copy, and whether a local
//  login is still waiting to be pushed (login happened while kaiosmini was
//  unreachable). Kept dependency-free so it compiles in a standalone
//  swiftc test harness. Spec: docs/superpowers/specs/2026-07-05-fleet-auth-sync-design.md
//

import Foundation

enum FleetCookieAction: Equatable {
    /// Overwrite the local cookie with the server's (server-wins: pushes only
    /// happen at fresh-login moments, so the server copy is the newest).
    case adoptServer(String)
    /// A local login never reached the server — push it instead of letting
    /// server-wins clobber the only fresh copy.
    case pushLocal
    case none
}

func decideFleetCookieAction(local: String, server: String?, pendingPush: Bool) -> FleetCookieAction {
    if pendingPush && !local.isEmpty {
        return .pushLocal
    }
    guard let server, !server.isEmpty, server != local else {
        return .none
    }
    return .adoptServer(server)
}

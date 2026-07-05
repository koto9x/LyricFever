# Fleet Auth Sync — Design

**Date:** 2026-07-05
**Branch:** `feat/plexamp-integration` (koto-only; MUST stay out of upstream PR carves)
**Status:** Approved by Koto 2026-07-05

## Problem

Lyric Fever's Spotify auth is a single UserDefaults string — the `sp_dc` cookie under
key `spDcCookie` — captured per machine via webview login or manual paste during
onboarding. It expires roughly yearly and is invalidated by Spotify password changes.
Every fleet machine (asgard16, k13, koto16, any future node) currently requires its own
login, and cold installs / bundle-id moves lose it entirely. The Music Assistant token
(`musicAssistantToken`, 395 chars) has the same shape and is copied by hand today.

Apple Music is **not** part of this problem: its "login" is MusicKit's
`MusicAuthorization.request()` — a one-click per-device OS consent tied to the Apple ID,
plus TCC. There is no credential file to sync, and unsigned builds (k13/koto16) can't
use MusicKit regardless. Out of scope.

## Goals

- Log in to Spotify once, on any fleet machine; every other machine picks up the fresh
  cookie automatically (on next launch).
- New devices bootstrap fully: build, launch, lyrics work — no onboarding dance.
- Cookie expiry costs exactly one re-login, anywhere, once.
- Zero behavior change when kaiosmini is unreachable (best-effort sync only).

## Non-goals

- Syncing Apple Music auth (nothing to sync — see above).
- Upstreaming any of this (self-hosted-server dependency; koto-specific).
- iCloud KVS / Keychain sync (requires signed builds with iCloud entitlements on every
  machine; k13/koto16 build with `CODE_SIGNING_ALLOWED=NO`).
- General settings sync. Only the whitelisted keys below.

## Architecture

kaiosmini (already the fleet's lyric server via lyric-fetch, port 8676, launchctl
service `studio.9x.lyric-dash`) becomes the source of truth for shared app secrets.

```
login on any machine ──POST /api/config──▶ kaiosmini fleet-config.json
                                                 │
every machine, every launch ◀──GET /api/config──┘  (server-wins for spDcCookie)
```

### Server (kaiosmini `~/lyric-fetch/app.py`)

Two endpoints on the existing Flask app:

- `GET /api/config` → contents of `~/lyric-fetch/fleet-config.json` as JSON.
- `POST /api/config` → JSON body; merge **only whitelisted keys** into the file;
  reject unknown keys (400). Atomic write (tmp + rename), file mode 600. Sets
  `updatedAt` (ISO 8601) on each successful merge.

Whitelisted keys: `spDcCookie`, `musicAssistantToken`, `musicAssistantHost`,
`useMusicAssistant`, `hasOnboarded`.

**Guard (both endpoints):** refuse with 403 unless `request.remote_addr` is inside the
Tailscale CGNAT range `100.64.0.0/10`. Requests arriving through the public Caddy proxy
(`lyrics.9x.studio`) come from `127.0.0.1` and are therefore refused — no Caddy config
change needed. Tailnet membership is the auth boundary, the same trust model already
used for the MA token and the lyric endpoints.

**Seeding:** initialize `fleet-config.json` once from asgard16's current live values
(container-store `spDcCookie` + `musicAssistantToken` + `musicAssistantHost`,
`useMusicAssistant: true`, `hasOnboarded: true`).

**Backup convention:** copy `app.py` to `app.py.bak.YYYYMMDD[x]` before editing, per
existing practice.

### Client (fork)

New file `LyricFever/Support Files/FleetConfig.swift` — a small `FleetConfigClient`
with `pull()` and `push(cookie:)`. Base URL: same host constant style as
`Lyrics9xLyricProvider` (`http://100.114.244.6:8676`, already covered by the scoped ATS
exception). Timeouts: 3s request. All calls best-effort and silent on failure.

**Pull — on every app launch**, off the critical path (async, never blocks startup):

- `spDcCookie`: if server value is non-empty and differs from local → **adopt server
  value** (server wins). Rationale: pushes happen only at fresh-login moments, so the
  server copy is always the newest. This is what propagates a yearly renewal to the
  whole fleet.
- `musicAssistantToken`, `musicAssistantHost`, `hasOnboarded`, `useMusicAssistant`:
  **fill only if locally empty/unset** — per-machine overrides survive.

**Push — on login:** both capture paths (webview capture in
`ViewModel.checkIfLoggedIn()` ~line 831, and manual paste in `ApiView`) write the same
defaults key via `UserDefaultStorage.cookie` / `@AppStorage("spDcCookie")`. Hook the
cookie-change point in `UserDefaultStorage` (didSet-equivalent on the observable
property): when the value changes to a new non-empty string, fire-and-forget
`POST /api/config {"spDcCookie": …}`. Guard against push-loops: the pull path sets a
flag (or compares against last-pulled value) so adopting a server value does not
re-push it.

**Offline-login edge:** if a push fails (kaiosmini down at login time), record a
pending-push marker in defaults. On next launch, a pending local cookie is **pushed
instead of being overwritten** by the pull — otherwise server-wins would clobber the
only fresh copy. The marker clears on successful push.

## Error handling

- kaiosmini unreachable / non-200 / malformed JSON → log via `print()`, do nothing;
  the app behaves exactly as today.
- Server: unknown keys → 400; non-tailnet caller → 403; concurrent POSTs are
  last-writer-wins (single user, acceptable).

## Security

- `sp_dc` grants full Spotify web-session access. It lives in one mode-600 file on
  kaiosmini, readable/writable only from tailnet nodes. Accepted trade-off, consistent
  with the fleet's existing trust model.
- Never log cookie/token values (lengths only, if needed).

## Testing / verification

1. Server: `curl http://100.114.244.6:8676/api/config` from asgard16 → 200 with seeded
   JSON; `curl -X POST` with a whitelisted key → 200 and file updated; POST with an
   unknown key → 400; `curl https://lyrics.9x.studio/api/config` → 403.
2. Client pull (the real test): on k13, delete `spDcCookie`
   (`defaults delete inc.kotopia.lyricfever spDcCookie`), relaunch Lyric Fever →
   Spotify lyrics work with no login; key repopulated (length ≈ 211).
3. Client push: re-run Spotify login (or paste a marker value via ApiView) on one
   machine → `fleet-config.json` `updatedAt` + value change on kaiosmini; relaunch on
   another machine → new value adopted.
4. Regression: with kaiosmini stopped, app launches and plays lyrics normally.

## Rollout

1. Server endpoint + seed on kaiosmini (no app change needed yet).
2. Client change on asgard16, build, verify pull/push locally.
3. Fleet: k13 pulls branch + rebuilds (`DEVELOPER_DIR=…` per memory note); koto16 via
   the k13 `rsync` deploy path (can't build until Xcode ≥16.3).

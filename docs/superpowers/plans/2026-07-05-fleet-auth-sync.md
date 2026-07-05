# Fleet Auth Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Spotify login anywhere on the fleet propagates the `sp_dc` cookie (plus MA token / onboarding bootstrap) to every Lyric Fever install via a tailnet-guarded `/api/config` on kaiosmini.

**Architecture:** kaiosmini's existing lyric-fetch Flask service gains GET/POST `/api/config` backed by a mode-600 `fleet-config.json` (tailnet-callers-only). The fork gains a `FleetConfig` client: pull-and-apply on every launch (server-wins for the cookie, fill-if-empty for the rest, pending-push guard for offline logins), push after a validated login.

**Tech Stack:** Python 3.9 / Flask (kaiosmini), Swift (fork, branch `feat/plexamp-integration`), curl + standalone `swiftc` harness for tests.

**Spec:** `docs/superpowers/specs/2026-07-05-fleet-auth-sync-design.md`

## Global Constraints

- Koto-only: none of this ever lands in upstream PR carves.
- Server code must run on Python 3.9 (kaiosmini's venv).
- Never log cookie/token **values** — lengths only.
- All client sync calls best-effort: 3s request timeout, silent failure, never block launch.
- kaiosmini edit convention: back up `app.py` → `app.py.bak.20260705c` before editing (a and b exist).
- asgard16 builds with the project's REAL signing (ad-hoc `CODE_SIGN_IDENTITY="-"` hangs the sandboxed app pre-main); k13 builds unsigned with `CODE_SIGNING_ALLOWED=NO` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Whitelisted config keys, exactly: `spDcCookie`, `musicAssistantToken`, `musicAssistantHost`, `useMusicAssistant`, `hasOnboarded`.

---

### Task 1: `/api/config` endpoints on kaiosmini

**Files:**
- Modify: `kaiosmini:~/lyric-fetch/app.py` (append before the `if __name__ == "__main__":` block, ~line 1105)

**Interfaces:**
- Produces: `GET /api/config` → 200 JSON object (or `{}` if unseeded); 403 for non-tailnet callers. `POST /api/config` (JSON object, whitelisted keys only) → 200 `{"ok": true, "updatedAt": …}`; 400 unknown keys / non-object body; 403 non-tailnet. State file `~/lyric-fetch/fleet-config.json`, mode 600.

- [ ] **Step 1: Contract test — verify endpoints don't exist yet**

Run from asgard16:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://100.114.244.6:8676/api/config
```
Expected: `404`

- [ ] **Step 2: Back up app.py**

```bash
ssh kaiosmini 'cp ~/lyric-fetch/app.py ~/lyric-fetch/app.py.bak.20260705c'
```

- [ ] **Step 3: Append the endpoints**

Add this block to `~/lyric-fetch/app.py` immediately BEFORE the `if __name__ == "__main__":` line. (`json`, `os`, `time`, `threading`, `request`, `jsonify` are already imported at the top of the file; only `ipaddress` is new.)

```python
# ---------------------------------------------------------------------------
# Fleet config: shared LyricFever secrets (sp_dc cookie, MA token) so one
# Spotify login covers the whole fleet. Tailnet-only: callers must originate
# from the Tailscale CGNAT range; public Caddy / tailscale-serve proxies
# arrive as 127.0.0.1 and are refused. Spec lives in the LyricFever fork:
# docs/superpowers/specs/2026-07-05-fleet-auth-sync-design.md
import ipaddress

FLEET_CONFIG_PATH = os.path.expanduser("~/lyric-fetch/fleet-config.json")
FLEET_CONFIG_KEYS = {"spDcCookie", "musicAssistantToken", "musicAssistantHost",
                     "useMusicAssistant", "hasOnboarded"}
_TAILNET = ipaddress.ip_network("100.64.0.0/10")
_fleet_lock = threading.Lock()


def _fleet_caller_allowed():
    try:
        return ipaddress.ip_address(request.remote_addr) in _TAILNET
    except ValueError:
        return False


@app.get("/api/config")
def fleet_config_get():
    if not _fleet_caller_allowed():
        return jsonify(error="forbidden"), 403
    try:
        with open(FLEET_CONFIG_PATH, encoding="utf-8") as f:
            return jsonify(json.load(f))
    except FileNotFoundError:
        return jsonify({})
    except Exception as e:
        return jsonify(error=str(e)), 500


@app.post("/api/config")
def fleet_config_set():
    if not _fleet_caller_allowed():
        return jsonify(error="forbidden"), 403
    body = request.get_json(silent=True)
    if not isinstance(body, dict) or not body:
        return jsonify(error="json object body required"), 400
    unknown = set(body) - FLEET_CONFIG_KEYS
    if unknown:
        return jsonify(error="unknown keys: %s" % sorted(unknown)), 400
    with _fleet_lock:
        try:
            with open(FLEET_CONFIG_PATH, encoding="utf-8") as f:
                cfg = json.load(f)
        except (FileNotFoundError, ValueError):
            cfg = {}
        cfg.update(body)
        cfg["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        tmp = FLEET_CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, FLEET_CONFIG_PATH)
    return jsonify(ok=True, updatedAt=cfg["updatedAt"])
```

- [ ] **Step 4: Syntax-check, restart the service**

```bash
ssh kaiosmini '~/lyric-fetch/venv/bin/python -m py_compile ~/lyric-fetch/app.py && launchctl kickstart -k gui/$(id -u)/studio.9x.lyric-dash && sleep 2 && curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8676/api/lookup'
```
Expected: py_compile silent; final curl prints a non-000 code (service is back; 400 is fine — /api/lookup without params). If py_compile fails: restore from `app.py.bak.20260705c`, fix, retry.

- [ ] **Step 5: Contract tests pass**

From asgard16:
```bash
curl -s http://100.114.244.6:8676/api/config; echo
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://100.114.244.6:8676/api/config -H 'Content-Type: application/json' -d '{"bogusKey": 1}'
curl -s -o /dev/null -w '%{http_code}\n' https://lyrics.9x.studio/api/config
```
Expected, in order: `{}` (200, unseeded); `400`; `403` (arrives via proxy as 127.0.0.1).
Note (loopback caveat): the localhost curl in Step 4 must NOT hit /api/config — 127.0.0.1 is deliberately refused, so test only from a tailnet node.

---

### Task 2: Seed `fleet-config.json` from asgard16's live values

**Files:**
- Create (on kaiosmini, via POST): `~/lyric-fetch/fleet-config.json`

**Interfaces:**
- Consumes: Task 1's `POST /api/config`.
- Produces: seeded config all later tasks pull. Seed values come from asgard16's sandboxed container store — the freshest copy (if Koto completed the re-login prompt on asgard16, this is a brand-new cookie; if not, first post-deploy login self-heals the fleet via push).

- [ ] **Step 1: POST the seed from asgard16's container plist**

```bash
PLIST=~/Library/Containers/inc.kotopia.lyricfever/Data/Library/Preferences/inc.kotopia.lyricfever.plist
python3 - "$PLIST" <<'EOF' > /tmp/seed.json
import json, plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
json.dump({
    "spDcCookie": p.get("spDcCookie", ""),
    "musicAssistantToken": p.get("musicAssistantToken", ""),
    "musicAssistantHost": p.get("musicAssistantHost", "100.114.244.6:8095"),
    "useMusicAssistant": True,
    "hasOnboarded": True,
}, sys.stdout)
EOF
curl -s -X POST http://100.114.244.6:8676/api/config -H 'Content-Type: application/json' --data @/tmp/seed.json; echo
rm /tmp/seed.json
```
Expected: `{"ok": true, "updatedAt": "…"}`

- [ ] **Step 2: Verify seed round-trips (lengths only — never print values)**

```bash
curl -s http://100.114.244.6:8676/api/config | python3 -c 'import json,sys; c=json.load(sys.stdin); print({k: (len(v) if isinstance(v,str) else v) for k,v in c.items()})'
ssh kaiosmini 'stat -f "%Lp %N" ~/lyric-fetch/fleet-config.json'
```
Expected: `spDcCookie` length ≈ 211, `musicAssistantToken` 395, host string 18, bools true; stat prints `600 …/fleet-config.json`.

---

### Task 3: Cookie decision logic (pure) + standalone harness test

**Files:**
- Create: `LyricFever/Support Files/FleetConfigDecision.swift`
- Test: standalone harness at `$SCRATCHPAD/fleet-decision-tests.swift` (compiled with `swiftc` — `xcodebuild test` hangs with this app as test host, per project memory)

**Interfaces:**
- Produces: `enum FleetCookieAction: Equatable { case adoptServer(String), pushLocal, none }` and `func decideFleetCookieAction(local: String, server: String?, pendingPush: Bool) -> FleetCookieAction`. Task 4's `FleetConfig.pullAndApply()` calls this exact signature.

- [ ] **Step 1: Write the failing harness test**

Write `$SCRATCHPAD/fleet-decision-tests.swift`:
```swift
// Compile together with FleetConfigDecision.swift; asserts crash on failure.
func expect(_ got: FleetCookieAction, _ want: FleetCookieAction, _ name: String) {
    if got == want { print("PASS \(name)") } else { print("FAIL \(name): got \(got), want \(want)"); exit(1) }
}
import Foundation
// Cold install: adopt server cookie
expect(decideFleetCookieAction(local: "", server: "srv", pendingPush: false), .adoptServer("srv"), "cold-install-adopts")
// Expired-local case: server differs → server wins
expect(decideFleetCookieAction(local: "old", server: "new", pendingPush: false), .adoptServer("new"), "server-wins")
// In sync: nothing to do
expect(decideFleetCookieAction(local: "same", server: "same", pendingPush: false), .none, "in-sync-noop")
// Server unreachable/unseeded: nothing to do
expect(decideFleetCookieAction(local: "loc", server: nil, pendingPush: false), .none, "no-server-noop")
expect(decideFleetCookieAction(local: "loc", server: "", pendingPush: false), .none, "empty-server-noop")
// Offline-login edge: pending local push beats server-wins
expect(decideFleetCookieAction(local: "fresh", server: "stale", pendingPush: true), .pushLocal, "pending-push-beats-server")
// Pending flag but nothing local to push: fall through to adopt
expect(decideFleetCookieAction(local: "", server: "srv", pendingPush: true), .adoptServer("srv"), "pending-empty-local-adopts")
print("ALL PASS")
```

- [ ] **Step 2: Run to verify it fails (function not defined)**

```bash
cd ~/Developer/LyricFever && swiftc -o /tmp/fleet-decision-test "LyricFever/Support Files/FleetConfigDecision.swift" "$SCRATCHPAD/fleet-decision-tests.swift" && /tmp/fleet-decision-test
```
Expected: FAILS to compile — `FleetConfigDecision.swift` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `LyricFever/Support Files/FleetConfigDecision.swift`:
```swift
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
```

- [ ] **Step 4: Run harness — all pass**

Same command as Step 2. Expected: `PASS` ×7 then `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/LyricFever && git add "LyricFever/Support Files/FleetConfigDecision.swift" && git commit -m "feat: fleet cookie decision logic (koto-only fleet auth sync)"
```

---

### Task 4: FleetConfig client + wiring + asgard16 build

**Files:**
- Create: `LyricFever/Support Files/FleetConfig.swift`
- Modify: `LyricFever/ViewModel.swift` (~line 646, inside `init()`, right after the `Task { mustUpdateUrgent … }` block and BEFORE the `latestUpdateWindowShown`/empty-cookie early returns)
- Modify: `LyricFever/Views/OnboardingView/ApiView.swift` (`checkForLogin()`, ~line 121)

**Interfaces:**
- Consumes: `decideFleetCookieAction(local:server:pendingPush:)` from Task 3; Task 1's HTTP contract.
- Produces: `FleetConfig.shared.pullAndApply() async`, `FleetConfig.shared.push(cookie: String) async`. Xcode project is filesystem-synced — new files are picked up automatically.

- [ ] **Step 1: Create `LyricFever/Support Files/FleetConfig.swift`**

```swift
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
```

- [ ] **Step 2: Kick off the pull in `ViewModel.init()`**

In `LyricFever/ViewModel.swift`, directly after the existing block
```swift
        // Check if user must urgently update (overrides menubar)
        Task {
            mustUpdateUrgent = await updaterService.urgentUpdateExists
        }
```
add:
```swift
        // Fleet auth sync (koto-only): pull the shared Spotify cookie / MA
        // token from kaiosmini. Must be kicked off BEFORE the early returns
        // below so cold installs bootstrap even when onboarding would run.
        Task {
            await FleetConfig.shared.pullAndApply()
        }
```

- [ ] **Step 3: Push after validated login in `ApiView.checkForLogin()`**

Both login paths (webview capture via `ViewModel.checkIfLoggedIn()` and manual paste) converge here, and `generateAccessToken()` succeeding is the validation. Change the `do` block to:
```swift
            do {
                try await ViewModel.shared.spotifyLyricProvider.generateAccessToken()
                isShowingDetailView = true
                errorMessage = nil
                ViewModel.shared.userDefaultStorage.hasOnboarded = true
                // Fleet auth sync (koto-only): a validated fresh cookie is the
                // fleet's new source of truth.
                await FleetConfig.shared.push(cookie: ViewModel.shared.userDefaultStorage.cookie)
            } catch {
```
(Deliberate non-goal: the Log Out button clears the local cookie but does not clear the server's — on a single-user fleet, re-adopting on next launch is the desired "stay logged in" behavior.)

- [ ] **Step 4: Build on asgard16 (real signing — NOT ad-hoc)**

```bash
cd ~/Developer/LyricFever && xcodebuild -project "Lyric Fever.xcodeproj" -scheme SpotifyLyricsInMenubar -configuration Debug -derivedDataPath ./build -skipMacroValidation build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/LyricFever && git add "LyricFever/Support Files/FleetConfig.swift" LyricFever/ViewModel.swift LyricFever/Views/OnboardingView/ApiView.swift && git commit -m "feat: fleet auth sync — pull on launch, push on login (koto-only)"
```

---

### Task 5: Live verification on asgard16

**Files:** none (behavioral verification)

**Interfaces:**
- Consumes: Task 2's seeded server, Task 4's built app at `./build/Build/Products/Debug/Lyric Fever.app` (symlinked as `/Applications/Lyric Fever (dev).app`).

- [ ] **Step 1: Cold-boot pull test — delete the local cookie, relaunch, watch it come back**

Quit first so cfprefsd flushes, then delete from the CONTAINER store (asgard16's app is sandboxed — plain-domain `defaults delete inc.kotopia.lyricfever` would hit the wrong plist):
```bash
killall "Lyric Fever" 2>/dev/null; sleep 1
defaults delete ~/Library/Containers/inc.kotopia.lyricfever/Data/Library/Preferences/inc.kotopia.lyricfever spDcCookie
open "/Applications/Lyric Fever (dev).app"
sleep 8
/usr/libexec/PlistBuddy -c "Print :spDcCookie" ~/Library/Containers/inc.kotopia.lyricfever/Data/Library/Preferences/inc.kotopia.lyricfever.plist | awk '{print "cookie length:", length($0)}'
```
Expected: `cookie length: ~211` (repopulated from kaiosmini) and NO onboarding/login window stuck on screen. If the length is 0/missing, launch the binary directly with stdout redirected (`"…/Contents/MacOS/Lyric Fever" > /tmp/lf-stdout.log 2>&1 &`) and grep `/tmp/lf-stdout.log` for `FleetConfig:` lines (print() is stdout-only, per project memory).

- [ ] **Step 2: Regression — kaiosmini-down behaves like today**

The pull is one GET with a 3s timeout and every failure path returns without touching defaults (verified by code reading in Task 4 review; do not actually stop the shared lyric service for this).

- [ ] **Step 3: Push path**

Already covered: unit-tested decision logic (Task 3), curl contract test (Task 1). Full app-side push fires on the next real login — verify opportunistically when Koto next logs in (watch `updatedAt` move on kaiosmini).

---

### Task 6: Fleet rollout — k13 (cold-boot acceptance) + koto16

**Files:**
- Modify (remote): `k13:~/Developer/LyricFever` (git pull + rebuild), `koto16:~/Developer/LyricFever/build/…` (rsync deploy from k13)

**Interfaces:**
- Consumes: commits from Tasks 3-4 pushed to `koto9x/LyricFever` `feat/plexamp-integration` (remote is named `origin` on k13/koto16).

- [ ] **Step 1: Push the branch from asgard16**

```bash
cd ~/Developer/LyricFever && git push koto9x feat/plexamp-integration
```

- [ ] **Step 2: Pull + rebuild on k13 (unsigned, per k13 convention)**

```bash
ssh k13 'cd ~/Developer/LyricFever && git pull origin feat/plexamp-integration && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project "Lyric Fever.xcodeproj" -scheme SpotifyLyricsInMenubar -configuration Debug -derivedDataPath ./build -skipMacroValidation CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3'
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: THE acceptance test — k13 cold-boots Spotify auth with zero login**

k13 is unsandboxed → plain domain works with the `defaults` CLI:
```bash
ssh k13 'killall "Lyric Fever" 2>/dev/null; sleep 1; defaults delete inc.kotopia.lyricfever spDcCookie 2>/dev/null; open "/Applications/Lyric Fever (dev).app"; sleep 8; defaults read inc.kotopia.lyricfever spDcCookie | awk "{print \"k13 cookie length:\", length(\$0)}"'
```
Expected: `k13 cookie length: ~211` — pulled from kaiosmini, no login UI.

- [ ] **Step 4: koto16 via the rsync deploy path (skip gracefully if unreachable)**

koto16 can't build (Xcode 16.2 SPM failure, per memory). Deploy k13's build products:
```bash
ssh k13 'rsync -a --delete ~/Developer/LyricFever/build/Build/Products/Debug/ koto16:~/Developer/LyricFever/build/Build/Products/Debug/'
ssh koto16 'killall "Lyric Fever" 2>/dev/null; sleep 1; open "/Applications/Lyric Fever (dev).app"'
```
Then repeat Step 3's cookie-length check against koto16. If koto16 is offline, note it and move on — it bootstraps on its next launch anyway.

---

### Task 7: Documentation + memory

**Files:**
- Modify: `~/Obsidian/MAINFRAME/MEMORY/project_lyric_fever.md` (prepend a STATUS section, matching the file's existing convention)

**Interfaces:**
- Consumes: outcomes of Tasks 1-6 (commit hashes, verification results).

- [ ] **Step 1: Add a STATUS section to the memory note**

Cover: what shipped (server endpoints + fleet-config.json on kaiosmini, FleetConfig client commits), the server-wins/pending-push rules, the tailnet-only guard (and that localhost/Caddy-proxied calls get 403 by design), how to rotate/inspect the config (`curl` GET, POST from any tailnet node), the app.py backup name, and that Apple Music has nothing to sync (MusicKit per-device consent).

- [ ] **Step 2: Final commit + push if anything is uncommitted**

```bash
cd ~/Developer/LyricFever && git status -s && git push koto9x feat/plexamp-integration
```

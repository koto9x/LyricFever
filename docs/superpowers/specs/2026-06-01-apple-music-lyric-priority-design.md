# Apple Music as a First-Class Lyric Source

**Status:** Draft — pending user sign-off
**Date:** 2026-06-01
**Branch context:** `feat/plexamp-integration` (koto9x fork); also targets three upstream PRs to `aviwad/LyricFever`.

## Problem

For brand-new releases by major artists (concrete recurring example: aespa — *LEMONADE — The 2nd Album*), LyricFever's current chain (`lyrics9x → spotify → lrclib → netease`) returns lyrics for the **wrong track** or with **wrong timing**. Apple Music itself has the correct synchronized lyrics natively, but LyricFever currently has no way to read them. Refresh hangs, manual offset doesn't help (it's not an offset problem — it's a wrong-song problem), and MusicKit had previously been ruled out on auth grounds.

The user has now opted in to **one** MusicKit authorization, unblocking Apple Music as a source.

## Goals

1. When `currentPlayer == .appleMusic` AND the track has a catalog `appleMusicID`, fetch lyrics from Apple Music's catalog API as the **top-priority** source.
2. Prefetch lyrics for the **containing album** (and a 5-track **queue sliding window**) in the background, so subsequent skips/auto-advance load instantly from cache.
3. When the user manually picks a lyric source via SearchWindow, that pick is **sticky** — never overridden by future network fetches for that track.
4. Land three of the changes upstream to `aviwad/LyricFever` so the wider community benefits.

## Non-Goals

- Apple Music API used when `currentPlayer != .appleMusic` (Plexamp/Spotify keep their existing chains — querying AM by title/artist would re-introduce wrong-song matches).
- Replacing the existing chain wholesale — AM is added as a new top tier, others remain as fallbacks.
- Karaoke-style word-level highlighting (TTML supports it; out of scope for v1).
- Lyrics for the Plexamp chain (already handled by self-hosted `lyrics9x` server).

---

## Architecture & Components

### New types

| Type | Role |
|---|---|
| `AppleMusicLyricProvider` | Conforms to existing `LyricProvider`. Wraps `MusicDataRequest` to hit `GET /v1/catalog/{storefront}/songs/{id}/lyrics`. The `{storefront}` segment is auto-resolved by MusicKit from the signed-in user's region — we never compute it ourselves. Parses TTML into the existing `NetworkFetchReturn` shape. |
| `AppleMusicAuthManager` | `@MainActor` singleton. Wraps `MusicAuthorization.currentStatus` and `MusicAuthorization.request()`. Token persistence is delegated to Apple's framework. |
| `AppleMusicPrefetcher` | `actor`. Orchestrates album + queue-window prefetch via bounded TaskGroup (concurrency cap 4). Writes results to CoreData on a background context. |
| `AppleMusicAuthView` | SwiftUI sheet shown on first AM track change when status is `.notDetermined`. Explains scope + triggers `request()`. |
| `TTMLParser` | Stateless parser. Apple's TTML lyrics → `[LyricLine]` matching existing schema. |

### Modified types

- **`ViewModel`** — instantiates `AppleMusicAuthManager` + `AppleMusicPrefetcher`. Extracts catalog `appleMusicID` from Music.app via AppleScript (`apple music ID of current track`). Reorders `allNetworkLyricProviders` to put `AppleMusicLyricProvider` at index 0 when `currentPlayer == .appleMusic && appleMusicID != nil`.
- **`SongObject` (CoreData)** — adds four nullable/defaulted fields: `appleMusicID`, `sourceProvider`, `userPicked`, `albumID`.
- **`SearchWindow`** — when the user applies a result, set `userPicked = true` and `sourceProvider = "user_picked"` on the saved object.

### Chain order

| `currentPlayer` | Has `appleMusicID` | Chain |
|---|---|---|
| `.appleMusic` | Yes | CoreData → **AppleMusicLyricProvider** → spotify → lrclib → netease |
| `.appleMusic` | No (e.g. imported MP3) | CoreData → spotify → lrclib → netease |
| `.plexamp` | n/a | CoreData → lyrics9x → spotify → lrclib → netease *(unchanged)* |
| `.spotify` | n/a | CoreData → spotify → lyrics9x → lrclib → netease *(unchanged)* |

CoreData lookup short-circuits the network chain entirely if `userPicked == true`.

---

## Authorization Flow

**Trigger points:**
- On launch: silent `MusicAuthorization.currentStatus` check. If `.notDetermined`, no action.
- On first `currentPlayer == .appleMusic` track change with `.notDetermined` → present `AppleMusicAuthView` sheet.
- `.denied` / `.restricted` → one-time toast directing user to System Settings → Privacy → Media & Apple Music. Suppress AM provider for the session.
- Always: Settings panel includes a "Re-link Apple Music" button calling `MusicAuthorization.request()`.

**Token lifecycle:** The MusicUserToken is held by Apple's framework in the system keychain. We never touch the raw token. Renewal is silent. A `401/403` from any `MusicDataRequest` flips our cached status to `.notDetermined` so the next AM track re-prompts.

**Prerequisite (one-time, dev-portal):** Add "MusicKit" service to the LyricFever App ID on the Asgard team. Note for [[project_apple_developer_pivot]]: re-add on the Kotopia team after Apple's developer-account pivot completes. Info.plist gains `NSAppleMusicUsageDescription`: *"LyricFever uses your Apple Music access to fetch synchronized lyrics for songs in Apple's catalog."*

---

## Data Flow

### On track change (AM player)

```
1. Extract metadata:
   - persistentID, appleMusicID, name, artist, album, albumID, duration

2. CoreData lookup:
   a. by appleMusicID → hit?
      - userPicked? → STOP (use cached, do not refresh)
      - else → use cached, but continue to step 4 (prefetch siblings)
   b. else by persistentID → hit?
      - userPicked? → STOP
      - else → use cached, continue to step 4

3. Cache miss → run network chain (table above):
   - AM provider success → write SongObject(sourceProvider="apple_music", lyrics, appleMusicID, albumID)
   - 404 → next provider
   - All providers exhausted → write SongObject(sourceProvider="none_found", lyrics=[]) → UI shows "Lyrics unavailable"

4. Fire-and-forget:
   - AppleMusicPrefetcher.warmAlbum(albumID)
   - AppleMusicPrefetcher.warmQueueWindow(5)
```

### `AppleMusicPrefetcher.warmAlbum(albumID: String)`

1. One `MusicDataRequest`: `/v1/catalog/{sf}/albums/{albumID}?include=tracks` → list of song IDs + names.
2. Diff against CoreData: skip already-cached songs (regardless of `userPicked`) and any song whose `appleMusicID` already has a `SongObject`.
3. `TaskGroup` with concurrency cap 4: per remaining song, fetch `/lyrics`, parse TTML, write `SongObject` with `albumID` populated.
4. All CoreData writes use a background context; merge to view context on completion.

### `AppleMusicPrefetcher.warmQueueWindow(n: Int)`

1. AppleScript best-effort enumeration of the next *n* tracks in Music.app's queue.
2. Music.app's queue API is limited; if enumeration fails, silently degrade to album-only prefetch.
3. Same diff + bounded fetch + write pipeline as `warmAlbum`.

---

## CoreData Schema Migration

**Mode:** Lightweight (automatic inference).
**Justification:** All new fields are optional / defaulted; no field renames; no relationship changes.

New on `SongObject`:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `appleMusicID` | `String?` | `nil` | Alternate lookup key for AM catalog tracks |
| `sourceProvider` | `String?` | `nil` | One of: `apple_music`, `spotify`, `lrclib`, `netease`, `lyrics9x`, `user_picked`, `none_found` |
| `userPicked` | `Bool` | `false` | Sticky-override flag |
| `albumID` | `String?` | `nil` | For album-prefetch dedupe + future album-aware features |

Set `NSPersistentStoreDescription.shouldInferMappingModelAutomatically = true`.

---

## Manual Override Semantics

**Apply path:** When the user clicks "Apply" in SearchWindow:
- `sourceProvider = "user_picked"`
- `userPicked = true`
- All other fields update normally

**Read path:** On track-change CoreData lookup:
- If `userPicked == true` → use cached lyrics, **do not** run network chain (even if AM provider would have succeeded).

**Bust path:** New menubar item "Reset lyrics for this track" → `userPicked = false; lyrics = nil; sourceProvider = nil` → next play re-runs the full chain. This same item also busts `sourceProvider == "none_found"` entries (see Error Handling), giving the user a single way to retry a previously-unavailable track if lyrics have since been added.

**`none_found` retry policy:** Sticky. Once cached, never auto-retried — same pattern as `userPicked`. Rationale: matches the user's mental model (one cache state per track), avoids surprise re-fetches, and the manual bust path covers the "lyrics were added later" edge case explicitly.

---

## Error Handling

| Condition | Behavior |
|---|---|
| `MusicAuthorization.currentStatus == .notDetermined` | Show `AppleMusicAuthView` sheet on first AM track |
| `.denied` / `.restricted` | One-time toast → System Settings; AM provider suppressed for session |
| `404` (track not in AM catalog) | Expected for imported MP3s; log debug; fall through chain |
| `401 / 403` token error | Flip cached auth status to `.notDetermined`; fall through this fetch; re-prompt on next AM track |
| Network timeout (10s) | Fall through; **do not** cache failure (next play retries) |
| TTML parse failure | Log warning; fall through |
| Whole chain empty | Write `SongObject(lyrics=[], sourceProvider="none_found")`; UI shows "Lyrics unavailable" instead of looping |
| Prefetch error (any kind) | Silent — never surface UI; demand-fetch on next play recovers |

---

## Testing

Honest assessment: most of this is integration-only because it depends on live MusicKit + Music.app. Test matrix:

### Automated (unit)

- **TTML parser** — fixture files: synced timestamps, plain-text-only fallback, malformed XML
- **Chain ordering** — `allNetworkLyricProviders` returns expected order for every `(currentPlayer, hasAppleMusicID)` combination
- **Schema migration** — load old-schema CoreData fixture; verify new fields default correctly; verify reads succeed

### Manual (smoke)

| Scenario | Expected |
|---|---|
| Play "Bite" by aespa on Music.app | Correct synced AM lyrics |
| Play imported MP3 (no catalog ID) | Chain falls to spotify; sourceProvider="spotify" |
| Open SearchWindow, apply LRClib result | `userPicked=true` in CoreData; replay same track produces no network calls (verify via console) |
| Play LEMONADE track 1, wait 5s, skip to next | Lyrics load instantly from prefetched cache |
| Revoke Apple Music access in System Settings, play AM track | Toast appears once; chain proceeds without AM |
| Open `Reset lyrics for this track` menu item, replay | Full chain re-runs |

---

## Upstream Contribution Plan

Three independent PRs to `aviwad/LyricFever` (cut off `main`, not off the fork's `feat/plexamp-integration`):

### PR-A — AppleMusicLyricProvider + auth (~600 LOC)
- `AppleMusicLyricProvider`, `AppleMusicAuthManager`, `AppleMusicAuthView`, `TTMLParser`
- ViewModel changes: chain reorder + `appleMusicID` extraction
- Info.plist + dev-portal capability docs (README section)
- **Headline feature** — broad community ask, lots of clout potential

### PR-B — SearchWindow auto-prefill + sticky `userPicked` (~150 LOC)
- SearchWindow `onAppear` already prefills name/artist (verified upstream); ensure prefill works reliably
- Schema: `userPicked: Bool` + `sourceProvider: String?` only (skip `appleMusicID`/`albumID` for this PR)
- Sticky-override read path in `fetchLyrics`
- "Reset lyrics for this track" menubar item
- **Universal-benefit UX fix**

### PR-C — Optional album prefetch (~250 LOC)
- `AppleMusicPrefetcher.warmAlbum` only (skip `warmQueueWindow` for upstream conservatism)
- Settings toggle: "Prefetch album lyrics in background" — **default OFF upstream**
- **Quality-of-life** — enables instant skip-around for power users

### Stays in our fork (not upstreamed)

- `lyrics9xLyricProvider` (self-hosted)
- 3-tier romanization + translation display
- Plexamp smart routing
- MediaRemote adapter for track-change detection
- Tailscale-specific ATS exception in Info.plist
- `warmQueueWindow` (uses our specific Music.app integration patterns)

ScrubBar / click-to-seek / past-ghost fade are flagged as **possibly upstreamable later** — not in this design's PR scope, revisit after these three land.

---

## Open Questions

None outstanding as of design-doc creation. All major branch points resolved during brainstorm:
- MusicKit auth: opted in ✓
- Prefetch scope: album + queue-window (B) ✓
- AM gated to AM player only: confirmed ✓
- Sticky manual override: confirmed ✓

## References

- [[project_lyric_fever]] — federated project memory; update after spec is approved
- [[project_apple_developer_pivot]] — note re: MusicKit capability needs re-adding on Kotopia team post-pivot
- Apple — [MusicKit framework](https://developer.apple.com/documentation/musickit) (Swift, native)
- Apple — [Apple Music API: Get a Song's Lyrics](https://developer.apple.com/documentation/applemusicapi/get_a_song_s_lyrics)
- Apple — [TTML lyrics format spec](https://developer.apple.com/documentation/applemusicapi/ttml) (linked from above)

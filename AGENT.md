# AGENT.md — RÚV Noise working conventions

macOS menu bar radio app (SwiftUI `MenuBarExtra`, LSUIElement, Swift 5, macOS 14+).
Owner's hard rule: **never cut a release without runtime verification.**

## Audio architecture

- `RuvNoise/RadioPlayer.swift` — player + `Station` enum + DSP glue.
- `RuvNoise/HLSStreamer.swift` — RÚV stations (Rás 1, Rás 2, Rondó): manual HLS playlist/segment download, `AVAudioFile` decode.
- `RuvNoise/LiveStreamer.swift` — all other stations: continuous HTTP audio (ICEcast/SHOUTcast, ADTS-AAC and MP3), frame-sync parsing, ICY metadata stripping + `StreamTitle` extraction (UTF-8 with Latin-1 fallback), reconnect with backoff.
- Both conform to `RadioStreamer` and yield `AVAudioPCMBuffer`s; `RadioPlayer` picks the streamer via `Station.isHLS`.
- DSP (FM / Kitchen / Clean modes) runs on buffers before scheduling — independent of source.
- Now playing: RÚV stations show schedule-based show titles (RÚV GraphQL API, `fetchShowSchedule`); live stations show ICY song titles (`nowPlayingLiveTitle`).

## Versioning — read this before any release

**`MARKETING_VERSION` in `RuvNoise.xcodeproj/project.pbxproj` (both Debug AND Release configs) is the single source of truth.** `Info.plist` derives both `CFBundleShortVersionString` and `CFBundleVersion` from `$(MARKETING_VERSION)`.

Never hardcode a separate build number: **Sparkle compares `CFBundleVersion` (the appcast `sparkle:version` attribute) first** — if two releases share a build number, auto-update silently stops offering updates ("X is currently the newest version available"). This exact bug shipped once; the repo is now structured to make it impossible, and CI enforces it (see workflows).

## Release ritual

1. Bump `MARKETING_VERSION` in **both** build configs of `project.pbxproj` (e.g. `2.4.0` → `2.4.1`).
2. Build Debug and verify the bundle:
   `defaults read <path>/RuvNoise.app/Contents/Info CFBundleShortVersionString CFBundleVersion`
3. **Test the actual change** (owner's rule): for streamer changes, run the app and/or a standalone harness — the streamer files are self-contained, so `swiftc -O RuvNoise/LiveStreamer.swift <harness-main.swift>` works directly.
4. Commit → push `main` → `git tag vX.Y.Z && git push origin vX.Y.Z`.
5. CI (`.github/workflows/release.yml`) builds, signs, notarizes, staples, uploads the release and publishes the Sparkle appcast to `gh-pages`. It refuses to release if the tag version isn't strictly newer than the published appcast, and refuses to publish an appcast that lacks the new version.
6. After a release, verify the live feed: `curl https://jokull.github.io/ruv-noise/appcast.xml` (the Pages URL — `raw.githubusercontent.com` caches up to 5 min).

## Engineering gotchas (learned the hard way)

- **`Data.removeFirst(_:)` is broken on macOS 26 Foundation**: it leaves a stale `startIndex` (e.g. `removeFirst(321)` → `startIndex == 321`), so the next `data[0]` subscript traps with SIGTRAP. Use `removeSubrange(0..<n)` or `Data(dropFirst(n))`. Never use `removeFirst` in this codebase.
- `project.pbxproj` is hand-edited with stable custom IDs (`A10001…`); run `plutil -lint` after any edit.
- Streams: RÚV = `ruv-radio-live.akamaized.net/streymi/<channel>/<channel>.m3u8` (HLS). Sýn/Vísir = `icecast.365net.is:8000/orb*.aac` (AAC+ ICEcast). Árvakur = `ice-11.spilarinn.is/*` (MP3). Some stations send empty ICY titles — that's source-side, not a bug.
- Do not commit build products (`build/`, `*.dmg`). Keep scratch files in `/tmp`.

## Repo layout

- `RuvNoise/` — app sources (`AppDelegate.swift` holds the menu; `RadioPlayer.swift` holds `Station`).
- `.github/workflows/release.yml` — tag-driven release pipeline.
- `.github/workflows/build.yml` — main/PR build check + version-consistency validation.
- `gh-pages` branch — Sparkle `appcast.xml`.

## Adding a station

Add a case to `Station` in `RadioPlayer.swift`: `url` (HLS for RÚV, ICEcast/MP3 otherwise), add it to `ruvStations` (RÚV → schedule titles) or `liveStations` (→ ICY titles), bump the version, release.

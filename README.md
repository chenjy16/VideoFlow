# VideoFlow

A native macOS app for downloading video and audio from any site supported by `yt-dlp`.

VideoFlow wraps `yt-dlp` and FFmpeg in a desktop UI: paste a link, inspect what the site
actually offers, pick a format, and watch the download progress in a task queue. Everything
runs locally — no account, no telemetry, no server component.

Built with Tauri 2 (Rust backend, React 19 + TypeScript frontend), SQLite storage, and
`yt-dlp` / `ffmpeg` / `ffprobe` shipped as bundled sidecar binaries.

---

## Features

### Download

- Paste a link (or use the clipboard button) and hit **Prepare** to inspect it with the
  bundled `yt-dlp` before anything touches the disk.
- Media summary shows title, duration, resolution, uploader, site, available format count
  and the `yt-dlp` version that produced the result.
- Format options are grouped into **Recommended**, **Video**, **Video only** and **Audio**;
  each option carries its real container, codecs, resolution, fps and estimated size.
- Container choice: **MP4** (remuxed or transcoded with FFmpeg), **MKV**, or the
  original container untouched.
- Audio-only extraction to **MP3**, **M4A** or **WAV** via FFmpeg.
- Engine readiness is verified before a task is queued, and a missing `yt-dlp` / FFmpeg /
  ffprobe surfaces as an explicit error instead of a half-finished file.

### Task queue

- Status is always reported by the backend — the UI never infers it:

  | Status | Meaning | Group |
  | --- | --- | --- |
  | `waiting` | Queued, waiting for a free slot | active |
  | `extracting` | Resolving formats and preparing the download | active |
  | `downloading` | Transferring bytes | active |
  | `merging` | FFmpeg muxing / extracting audio | active |
  | `completed` | File written and verified | finished |
  | `failed` / `cancelled` / `interrupted` | Terminal states with an error message | finished |

- Live progress over Tauri events: downloaded bytes, total size, speed, ETA and percent.
- Cancel a running task (SIGINT to the child process group first, SIGKILL after a grace
  period, so `yt-dlp` can keep its `.part` file and resume later).
- Retry failed tasks, remove the record without deleting the file, open the finished file,
  or reveal it in Finder.
- Configurable concurrency (default: 2).

### History

- Every task that reached a terminal state stays searchable: debounced text search,
  pagination, format / resolution / size / finished-at columns.
- Re-download an entry with its original URL and format.

### Settings

- Download folder (validated as an absolute path, no `..` segments).
- Default container and default quality (`best`, `1080p`, `720p`, `480p`, `360p`).
- Maximum concurrent downloads.
- Notification when a download finishes.
- Engine card listing the resolved `yt-dlp`, `ffmpeg` and `ffprobe` paths with versions.
- Third-party license viewer and a plain statement that nothing leaves the machine.

### Interface

- Four consistent pages — **Download**, **Tasks**, **History**, **Settings**.
- Design tokens (color, type scale, 32 px controls, 10 px radii) live in
  `src/styles/index.css`; components only consume semantic names.
- Light and dark themes follow the system appearance.
- Overlay title bar with explicit drag regions; buttons, inputs, selects, navigation items
  and scroll areas never start a window drag.
- Keyboard reachable controls with visible focus rings.
- English-only UI backed by a typed dictionary (`src/i18n/en.ts`): a missing or misspelled
  key is a TypeScript error, not a blank label at runtime.

---

## Requirements

| | Version |
| --- | --- |
| macOS | 11.0 or later |
| Architecture | Apple Silicon (`aarch64-apple-darwin`) only |
| Node.js (development) | `>=24.22.1 <25` (see `.nvmrc`) |
| pnpm (development) | `>=10.28.0 <11` |
| Rust (development) | pinned to `1.100.0` via `rust-toolchain.toml` |

## Install

Download the DMG from [Releases](https://github.com/chenjy16/VideoFlow/releases), mount it,
and drag `VideoFlow.app` into `/Applications`.

Released builds are **signed ad-hoc and not notarized** by Apple. Gatekeeper will refuse the
first launch; either open it from System Settings → Privacy & Security → *Open Anyway*, or strip
the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/VideoFlow.app
```

There is no Developer ID certificate behind it, so macOS reports it as an unidentified developer.
If you instead see *“VideoFlow.app” is damaged and can't be opened* — that message means the code
signature itself is invalid, not that the download was corrupted. Builds from **v1.0.0 and
earlier** were packaged without any `codesign` pass (only the linker signature on the Mach-O), so
that dialog appears for them; v1.0.1 and later are ad-hoc signed as a whole bundle and show the
regular unidentified-developer prompt. Either way the fix is the same `xattr` command above,
followed by a normal launch.

Verify the download before installing:

```bash
shasum -a 256 -c SHA256SUMS
```

`release-manifest.json` in the same release records the build kind, signing and notarization
status, bundled engine versions and license index. Do not judge a build by its file name — the
manifest is the source of truth.

## Development

```bash
pnpm install          # install JS dependencies
pnpm app:dev          # run the app with hot reload (Tauri dev)
pnpm app:build        # produce a local .app and .dmg
```

The bundled sidecars are not committed to the repository. Fetch `yt-dlp` with the pinned
version and checksum, and place the FFmpeg build in the same folder:

```bash
./scripts/fetch-yt-dlp.sh     # downloads src-tauri/binaries/yt-dlp-aarch64-apple-darwin
# then provide src-tauri/binaries/ffmpeg-aarch64-apple-darwin
#                src-tauri/binaries/ffprobe-aarch64-apple-darwin
```

`pnpm app:dev` only needs `yt-dlp`; FFmpeg and ffprobe are required for merging separate
streams and for audio extraction.

## Project structure

```
src/                        React frontend
  components/
    layout/                 app shell, sidebar, overlay title bar drag regions
    download/               media summary, format picker
    tasks/                  task card with progress and actions
    common/                 status badge, empty / loading / error states
    ui/                     button, input, select, card, dialog, alert
  pages/                    Download, Tasks, History, Settings
  store/                    zustand store (task list, progress, stale-snapshot guard)
  hooks/                    backend event subscriptions, system theme
  i18n/                     typed English dictionary
  lib/                      Tauri command wrappers, formatting helpers
  styles/index.css          design tokens, light and dark palettes

src-tauri/src/
  commands/                 thin Tauri command layer exposed to the frontend
  manager/                  queue scheduler, task lifecycle, progress aggregation
  engine/                   yt-dlp invocation, link validation, format mapping, engine paths
  domain/                   task, settings and media types
  storage/                  SQLite access (downloads, settings, download_logs)
  error.rs                  user-facing error variants

scripts/                    sidecar fetching, packaging, release verification and gating tests
docs/                       release, CI/CD, notarization and licensing documentation
```

## How it works

```
React UI ──invoke──▶ Tauri commands ──▶ DownloadManager ──spawn──▶ yt-dlp / ffmpeg
   ▲                                          │
   └──────── task:updated / task:progress ◀────┘  (Tauri events)
```

- The frontend calls named commands (`inspect_url`, `create_download`, `cancel_download`, …);
  it never shells out or touches the filesystem directly.
- `DownloadManager` owns the queue: it persists every task in SQLite first, then schedules up
  to `max_concurrent` tasks. Each running task is a child process in its own process group,
  with `yt-dlp` arguments passed as an array (no shell interpolation).
- Progress lines from `yt-dlp` are aggregated per task, persisted periodically and emitted as
  throttled events, so the UI stays smooth during large downloads.
- Task status transitions are monotonic. A command response that carries an older snapshot
  than an event already received is discarded, so a queued-looking state can never overwrite
  a running one.
- Only `http` and `https` links are accepted; every other scheme is rejected before `yt-dlp`
  is invoked.
- FFmpeg is required when separate audio/video streams must be merged or a track is extracted;
  the requirement is checked up front so a task never fails halfway through.

## Data locations

| What | Path |
| --- | --- |
| Database (SQLite, WAL) | `~/Library/Application Support/app.videoflow.desktop/videoflow.db` |
| Logs | `~/Library/Logs/app.videoflow.desktop/VideoFlow.log` |
| Default download folder | `~/Downloads/VideoFlow` |

The database holds three tables: `downloads` (task state, paths, sizes, timings),
`download_logs` (per-task `yt-dlp` output) and `settings` (user preferences).

## Quality gates

```bash
pnpm typecheck        # tsc --noEmit
pnpm lint             # eslint
pnpm format:check     # prettier --check
pnpm build            # typecheck + vite build

cd src-tauri
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test
```

The release pipeline adds its own gates, including `scripts/verify-release.sh` (architecture,
bundled engines, licenses, signature and notarization state) and
`scripts/test-release-gating.sh` (assertions over the workflow expressions and packaging
script). All of them run in CI on every push.

## Releasing

Version numbers must match in three places — `package.json`, `src-tauri/tauri.conf.json` and
`src-tauri/Cargo.toml`. Then push a tag:

```bash
git tag v0.1.1
git push origin v0.1.1
```

A `v*` tag builds, verifies, packages and publishes a GitHub **pre-release** containing the
DMG, the `.app.zip`, `SHA256SUMS`, `release-manifest.json`, `THIRD_PARTY_LICENSES.md` and
`SOURCE_OFFER.txt`. Existing releases are never overwritten — bump the version instead.
Signed and notarized releases require an Apple Developer account and the corresponding
secrets; that path is documented but not active.

See [docs/RELEASE.md](docs/RELEASE.md) for the full procedure.

## Third-party components

| Component | Version | License |
| --- | --- | --- |
| `yt-dlp` | 2026.10.26 (pinned, checksum verified) | Unlicense |
| FFmpeg / ffprobe | 8.0.1 static build | LGPL-2.1-or-later |
| LAME | bundled into FFmpeg | LGPL-2.0 |
| libopus | bundled into FFmpeg | BSD-3-Clause |

Full texts are in [docs/THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md) and the
`licenses/` directory, including the LGPL relinking materials in `SOURCE_OFFER.txt`.

This repository does not currently ship a license file for VideoFlow itself.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/RELEASE.md](docs/RELEASE.md) | Release modes, artifacts and user-facing notices |
| [docs/CI_CD.md](docs/CI_CD.md) | Workflow structure and permissions |
| [docs/NOTARIZATION.md](docs/NOTARIZATION.md) | Signing and notarization details and current status |
| [docs/THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md) | Third-party license texts |
| [docs/PLAN.md](docs/PLAN.md) | Delivery plan and phase history |

# Phase 1/2 — App shell + settings + native USB detection

A SwiftUI macOS app reproducing every field/control from
`src/ui/main_window.py`, backed by real settings persistence and now
real, native USB drive detection. Encoding, disk image authoring, and
writing are still not wired in — that's Phase 3 onward.

Run: `swift run` from this directory (`swift-port/BookMasterApp`).

## What's real

- **Settings persistence** (`Stores/SettingsStore.swift`) — a Codable
  `AppSettings` struct mirroring `src/settings.py`'s `DEFAULT_SETTINGS`
  key-for-key (`snake_case` JSON keys via `CodingKeys`, matching field
  names exactly), loaded/saved as JSON on every change, tolerant of
  missing/extra keys so old or hand-edited settings files still load.
  Verified end-to-end: launched the built app, confirmed
  `settings.json` was written with the correct default values and key
  names.
- **Config loading** (`Stores/ConfigStore.swift`) — a Codable
  `AppConfig` mirroring `src/config/config.json` (encoding params, drive
  size default, output structure, valid formats), loaded from a bundled
  resource copy with a built-in fallback if that ever fails to parse.
- **All UI fields present and bound**: input folder (+ native
  `NSOpenPanel` browse), skip image/encoding toggles, max drive size
  radio (480/980 MB), ISBN/SKU/title/author/file count fields with the
  same CSV-lookup-disables-fields behavior as the Python UI, USB test
  checkboxes (Silence/Loudness/Metadata/Frames/Speed) bound to the same
  comma-separated string format the Python side reads.
- **In-memory log panel** (`Stores/LogStore.swift`) — stands in for the
  Python UI's `ScrolledText` + `setup_logging()` panel.

## Phase 2 — native USB detection (new)

- **`Services/USBMonitor.swift`** promotes Phase 0's
  `DiskArbitrationSpike` into real app code: a `DASession` with
  appeared/disappeared/description-changed callbacks (threaded through a
  C-callback trampoline using `Unmanaged.passUnretained`, since
  `@convention(c)` callbacks can't capture `self`), publishing
  `[USBDriveInfo]` for SwiftUI to bind to directly. No polling.
- **`Models/USBDriveInfo.swift`** carries the same safety-relevant
  classification proven in Phase 0: `isCandidate` requires
  `isRemovable && isWhole && protocolName == "USB"` — removability alone
  is not enough (CoreSimulator volumes are removable but not USB; the
  internal boot disk's raw device path would pass a naive string-pattern
  check but never this classification). The list only ever shows
  candidates, not every mounted volume the way the Python UI's listbox
  did — a deliberate narrowing, since the only valid write target this
  app cares about is exactly this kind of device.
- **This is detection only.** `isCandidate` is the same gate Phase 4's
  write path will re-check live, immediately before writing — not
  something write code will be allowed to trust from this cached list.
- Capacity/free space and volume name come from `URL` resource values
  and DiskArbitration's own description dictionary — no more shelling
  out to `diskutil info` / `system_profiler`.
- **Deliberately out of scope for Phase 2** (this is genuinely Phase 7
  work, not an oversight): reading `bookInfo/id.txt` / `count.txt` off a
  mounted candidate to show SKU/ISBN/content-validity, the way the
  Python `USBDrive.content`/`is_valid_master` did. The panel says so
  explicitly rather than showing stale/fake values.

## What's deliberately stubbed

- **Create Master / Check Master / Batch Create buttons** just append a
  log line. No `MasterDraft`/`Master` equivalent exists yet.
- **Webcam panel** shows a placeholder rectangle. Real capture is Phase
  5, building on `../Spikes/Sources/BarcodeSpike`.

## Deliberate design choices worth flagging

- **Settings live under `~/Library/Application Support/BookMasterSwift/`**,
  not the Python app's `~/Library/Application Support/VoxblockMaster/`
  (via `platformdirs.user_config_dir("VoxblockMaster")`). This is
  intentional — a Phase 1 prototype must never read or silently
  overwrite the real production app's settings file on a dev machine
  that has both installed. Phase 9 (cutover) is where settings
  migration/compatibility gets decided deliberately, not implicitly
  here.
- **`config.json` is bundled as a package resource**, copied from
  `src/config/config.json` at scaffolding time — it will drift from the
  source of truth if that file changes and this copy isn't updated.
  Phase 9 packaging needs to decide the long-term story (bundled
  default vs. user-editable file), noted as a TODO rather than solved
  here.
- **Settings autosave on every change** (`onChange(of: settings)` ->
  `save()`), rather than only on window close like the Python app's
  `on_closing()`. This is a deliberate small improvement (no risk of
  losing UI state to a crash) — flagging it here since it's a behavior
  change from the original, not an oversight.

## Verified

- `swift build` succeeds cleanly (Phase 1 and Phase 2 additions both).
- Launched the built binary directly (`.build/debug/BookMasterApp`) with
  `USBMonitor` active, confirmed the process starts and stays running
  (no crash) for several seconds with the `DASession` registered and
  enumerating this machine's real disks (internal Apple Fabric disks +
  CoreSimulator virtual volumes — the same set Phase 0's spike saw).
  None of them are USB, so the negative-case safety property (never
  showing an internal/virtual disk as a write candidate) held with real
  callbacks firing against real hardware state, not just the isolated
  spike.
- Confirmed `settings.json` gets written on first launch with the exact
  expected default keys/values.
- **Not verified — no real USB drive attached to this machine during
  this session**: the positive case (a real USB stick appearing in the
  list with correct capacity/volume name), and live insert/remove
  reactivity. Needs a human to plug in a drive and confirm before Phase
  4 (writing) is built on top of this with full confidence.
- Could **not** visually confirm the window layout from this session
  (no Screen Recording / Accessibility permission available to script a
  screenshot or window query headlessly) — needs a human to run `swift
  run` and eyeball it once.

## Not yet done (candidates for follow-up, not blocking the next phase)

- No app icon / proper `.app` bundle with `Info.plist` yet — `swift run`
  launches it as a bare executable. Needed before Phase 5 (camera
  permission prompts require a real bundle) at the latest.
- No menu bar customization (still gets SwiftUI's default menu).
- No unit tests on `AppSettings`/`AppConfig` decoding, or on
  `USBDriveInfo.isCandidate`'s classification logic, yet — worth adding
  given how safety-relevant the latter is.

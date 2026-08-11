# BookMasterApp — Swift port

A SwiftUI macOS app reproducing `src/ui/main_window.py`, built up phase
by phase per the migration plan. Settings/config, native USB detection,
and FAT image authoring are real and tested; encoding and the raw write
are next.

Run: `swift run` from this directory (`swift-port/BookMasterApp`).
Test: `swift test`. The package now has three targets — `BookMasterCore`
(library: models/stores/services, unit-tested), `BookMasterApp`
(executable: views + app entry), `BookMasterCoreTests`.

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

## Phase 3 — FAT image authoring (new)

- **`Services/DiskImageBuilder.swift`** ports `diskimage.py`'s
  `create_disk_image()`: sizes a raw image from the source folder's
  actual disk usage (`du -sk`, same 5%-or-5MB buffer / 10MB floor math),
  formats it, copies files in (respecting `config.json`'s
  `patterns_to_remove` via real `fnmatch(3)`, matching Python's
  `fnmatch.fnmatchcase`), and publishes to the output path with the same
  read-only lock (`chmod 444` + `chflags uchg`) the Python version used.
- **Resolves Phase 0's open follow-up.** Rather than `hdiutil create`
  (UDIF-wrapped, needs flattening before it's byte-exact) this builds a
  bare truncated file directly and forces `hdiutil attach -imagekey
  diskimage-class=CRawDiskImage` to treat it as a raw device — verified
  the file's byte size never changes across the whole attach/format/
  mount/copy/detach cycle, so the result is already the flat image
  Phase 4 needs, no separate conversion step required.
- **Deliberately not ported**: the Google Drive watermarking/slot-log
  step (`claim_unique_slot_and_log`) — a business-process integration,
  not disk-image authoring.
- **Tested for real** (`Tests/BookMasterCoreTests/DiskImageBuilderTests.swift`):
  builds an image from a scratch folder with a nested directory, a
  normal file, and files matching exclude patterns; re-attaches
  read-only; asserts the FAT filesystem, correct file contents, and that
  excluded files were never copied. Not simulated — real `hdiutil`/
  `newfs_msdos` calls, real assertions on the result.

## Phase 4 — raw write with a double safety gate (new)

- **`Services/RawDeviceWriter.swift`** ports the write mechanics only:
  chunked POSIX `open`/`write`/`fsync` (proven correct via checksum
  round-trip in Phase 0), replacing `dd of=<raw_whole> bs=4m conv=fsync`.
- **`RawWriteAuthorization`** turns Phase 0/2's safety finding into a
  type, not just a runtime check: `RawDeviceWriter.write()` only accepts
  an `authorization` value, never a bare path — and the only way to get
  one is `authorize(drive:currentCandidates:)`, which requires **both**
  the `/dev/rdiskN` pattern match **and** a live re-lookup against the
  *current* candidate list (not a cached selection) confirming
  DiskArbitration still reports it as removable+whole+USB right now.
  Structurally impossible to write without passing both gates.
- **Deliberately NOT ported**: the Python version's `sudo -A dd ...`
  privilege escalation. Shelling out to `sudo` isn't something to carry
  into a signed, distributed app — the real replacement (a signed
  XPC/SMJobBless helper, or an AuthorizationServices prompt) needs
  actual signing infrastructure and belongs in Phase 9, not here. This
  writer just attempts a direct POSIX open/write and surfaces whatever
  `errno` comes back; macOS often grants the console user direct access
  to a *removable* device's node without elevation (unlike internal
  disks), so this may just work as-is — untested against real hardware
  either way.
- **Tested for real**: 7 tests, all passing — checksum round-trip on the
  write mechanics against a scratch file, and every gate-rejection case
  from Phase 0/2 as an actual assertion rather than a README claim:
  rejects the internal boot disk despite matching the path pattern,
  rejects a removable-but-non-USB device, rejects a partition slice,
  rejects a device no longer present in the live candidate list.
- **Not tested, and must not be, from an agent session**: an actual
  write to a real `/dev/rdiskN`. Needs a human, real hardware, a drive
  deliberately designated as expendable scratch.

## Phase 5 — live camera barcode scanning (new)

- **`Services/CameraScanner.swift`** is real, running `AVCaptureSession`
  + `VNDetectBarcodesRequest` wired into the actual UI (not just a
  design sketch this time): toggling "Webcam ISBN" requests camera
  access, starts the session, shows a live preview
  (`Views/CameraPreviewView.swift`, an `NSViewRepresentable` wrapping
  `AVCaptureVideoPreviewLayer`), and auto-fills the ISBN field the
  moment a plausible EAN-13 is detected — same 13-digit-numeric
  validation as `update_isbn()` in the Python UI, now a tested pure
  function (`isPlausibleISBN13`, 3 tests).
- **Resolved Phase 0's open question empirically, not by assumption.**
  Wrote and ran two throwaway probes (an interpreted `swift script.swift`
  and a compiled+ad-hoc-signed `swift build` product, both deleted after
  the check) calling `AVCaptureDevice.requestAccess`: both return
  `granted=false` **instantly, with no OS permission dialog at all**,
  and `authorizationStatus` stays `.notDetermined` rather than
  transitioning to `.denied`. `codesign -dv` on the compiled binary
  confirms why: `Info.plist=not bound` — there's no
  `NSCameraUsageDescription` for TCC to show a prompt for. This
  confirms a real `.app` bundle with a proper `Info.plist` is a **hard
  requirement** before camera access can work at all, not just best
  practice — the UI code above is real and correct, but genuinely
  cannot be exercised end-to-end until Phase 9 produces a real bundle.
- Frame-rate throttling (~3 Vision calls/sec, not 30) done directly on
  the capture delegate's own serial queue rather than hopping to the
  main actor first — avoids doing the throttle check itself as slowly
  as the thing it's throttling.

## What's deliberately stubbed

- **Create Master / Check Master / Batch Create buttons** just append a
  log line. No `MasterDraft`/`Master` equivalent exists yet — that's
  Phase 7, which is also where `DiskImageBuilder` gets wired into the UI.
- **Webcam panel** shows a placeholder rectangle until camera access is
  granted — the code is real (Phase 5), but per above it can't actually
  be exercised until Phase 9 produces a real app bundle.

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

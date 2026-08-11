# BookMaster Swift port — phase-by-phase history

> **This is a history document, not the current structure.** All the
> code described below now lives directly inside
> [`BookMaster.xcodeproj`](BookMaster.xcodeproj) as one unified Xcode
> project — see [`README.md`](README.md) for the current layout. There
> is no more separate `BookMasterApp`/`BookMasterCore` SwiftPM package;
> that existed for a while during the port (first as the whole app via
> `swift run`, then briefly as a local package dependency the Xcode
> project referenced) and was folded entirely into this project on the
> next iteration once it became clear a single unified project was
> wanted over a package-plus-thin-app-target split. `swift test`/
> `swift run` no longer apply anywhere in `swift-port/` — use
> `xcodebuild` or Xcode itself (see README.md).
>
> Paths mentioned below like `Sources/BookMasterCore/Services/X.swift`
> reflect where things lived *at the time each phase was written*, not
> where they are now (now: `BookMaster/Services/X.swift`, directly in
> the Xcode project). The technical content — what was built, how it
> was tested, what findings came out of it — is all still accurate.

A SwiftUI macOS app reproducing `src/ui/main_window.py`, built phase by
phase per the migration plan (Phases 0-9 below). Every core capability
— settings, native USB detection, FAT image authoring, a type-enforced
raw-write safety gate, live camera barcode scanning, ffmpeg encoding,
and the full Create/Check Master pipeline — is real, wired into the
running app, and covered by tests that exercise real system tools
(`hdiutil`, `newfs_msdos`, `ffmpeg`, `AVFoundation`), not simulations.

**What this is not, yet**: production-ready. Real-hardware validation
(an actual USB drive appearing, an actual device write), Developer ID
signing/notarization, and — most importantly — the decision to cut real
users over from the Python app are all explicitly out of scope for this
branch. See "Not done here, and why" under Phase 9.

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
  **Update from Phase 9**: confirmed fixed, with one more nuance —
  see Phase 9 below.
- Frame-rate throttling (~3 Vision calls/sec, not 30) done directly on
  the capture delegate's own serial queue rather than hopping to the
  main actor first — avoids doing the throttle check itself as slowly
  as the thing it's throttling.

## Phase 6 — ffmpeg encoding bridge (new)

- **`Services/FFmpegEncoder.swift`** ports `track.py`'s `Track.convert()`
  **byte-for-byte** as a command line — same `filter_complex` string
  (pink-noise dither mixed in at `a=0.0001` before `loudnorm`), same
  output args (`-ar`, `-ab`, `-ac 1`, `-f mp3`, `-acodec libmp3lame`).
  This is known-working production audio processing; the port
  reproduces it exactly rather than reinterpreting it.
- **`Services/AudioDuration.swift`** reads input duration via
  `AVFoundation` (`AVURLAsset.load(.duration)`) instead of shelling to
  `ffprobe` — one less subprocess, and it's already on every Mac.
- **`Services/BitrateFitting.swift`** ports `master.py`'s
  `calculate_encoding_for_drive_capacity()` as a pure, tested function:
  reduce bitrate proportionally when estimated size exceeds 90% of
  drive capacity, floored at 32kbps, never increased above the original.
- **AVFoundation was deliberately not used for the encoding itself** —
  it has no equivalent to `loudnorm`, and subtly-wrong loudness
  normalization would make every audiobook sound different depending on
  which engine built it. ffmpeg stays an external dependency; Phase 9
  needs to bundle+sign it.
- **Tested for real, not simulated**: generates an actual 2-second
  440Hz test tone via ffmpeg (no book audio needed), runs it through the
  exact production filter graph, and verifies the output is a valid MP3
  with the right duration and a single mono track. 6 new tests (4 for
  bitrate math, 2 for the encode pipeline), all passing — 19 total now.

## Phase 7 — metadata, checksums, and the full Create/Check Master pipeline (new)

This is where everything from Phases 3-6 gets tied together and the
"Create Master" / "Check Master" buttons stop being stubs.

- **`Services/BooksCatalog.swift`** ports `config.py`'s `_load_books_csv()`
  — a small hand-written CSV parser (RFC4180-ish: quoted fields, `""`
  escaping; no dependency pulled in for something this contained) over a
  bundled `books.csv` snapshot, keyed by ISBN. Faithfully reproduces an
  existing quirk rather than fixing it: `main_window.py` reads a
  non-existent `ExpectedFileCount` column and always silently gets `0`
  — the Swift version does the same, documented in a test, not "fixed"
  behind the scenes.
- **`Services/Checksum.swift`** ports `compute_sha256()`: one running
  SHA-256 fed each file's relative path then its contents, in
  natural-sorted order, excluding a handful of housekeeping files
  (`.DS_Store`, `version.txt`, `checksum.txt`, ...) so writing
  `checksum.txt` doesn't change the hash it just recorded.
- **`Services/NaturalSort.swift`** ports `natsort.natsorted` for real —
  publisher input filenames aren't zero-padded (`Chapter 2.mp3` vs.
  `Chapter 10.mp3`), so this isn't cosmetic; a test proves 1/2/10 encode
  in that order, not 1/10/2.
- **`Services/MasterBuilder.swift`** is the `MasterDraft`/`Master`
  equivalent: validates inputs (ports `MasterDraft.validate()`), finds
  and naturally-sorts input audio files, reuses already-processed tracks
  when `skip_encoding` is set and the count still matches (ports
  `process_tracks()`'s reuse check), encodes each track (Phase 6) at a
  drive-capacity-fitted bitrate (Phase 6's `BitrateFitting`), assembles
  the exact `output_structure` (`bookInfo/id.txt`, `count.txt`,
  `version.txt`, `.metadata_never_index`, `tracks/`), computes and
  writes the checksum, then builds the disk image (Phase 3). One
  function, same order of operations as the Python version, including
  the "checksum after tracks are copied, before checksum.txt is
  written" ordering dependency.
- **`Services/MasterReader.swift`** is the "Check Master" counterpart:
  reads `id.txt`/`count.txt` back off a mounted drive and re-verifies
  the stored checksum against a fresh computation — catching a tampered
  or corrupted drive, not just a missing one.
- **UI wiring**: ISBN field changes trigger the CSV lookup (when "CSV
  lookup" is on) exactly like `_on_isbn_change()`; "Create Master" runs
  the real async pipeline with progress logged live; "Check Master"
  reads the selected USB candidate's mounted content into the same
  detail panel Phase 2 built, replacing the "Phase 7 work" placeholder.
- **Still NOT wired to a real device write from the UI**: "Write image
  to block" is present but deliberately not auto-triggering
  `RawDeviceWriter` on a button click without the user explicitly
  selecting and confirming a drive — see Phase 4 and Phase 9 for why.
- **Tested for real, end-to-end, not simulated**: synthesizes three
  "publisher" tracks named non-sequentially (`Chapter 1/2/10.wav`), runs
  the *entire* pipeline, and asserts on the real result — correct
  natural-sort encoding order, `bookInfo` file contents, checksum
  presence, a FAT image that actually exists — plus a tamper-detection
  test (mutates a file after the checksum was written, confirms
  `MasterReader` catches it). 12 new tests, all passing — **29 total**.

## Phase 8 — safety-critical test harness

Every prior phase added real tests as it went (TDD-ish, not a
end-of-project batch) — 29 tests existed before this phase started.
Phase 8's job was to find and close the remaining gaps, and make the
safety-critical coverage easy for a future maintainer to find, not to
start testing from zero.

**Gaps closed:**
- `DiskImageBuilderTests.testBuildImageWithEmptySourceFolderHitsSizeFloor`
  — an empty source folder must still hit the 10MB size floor rather
  than producing something degenerate.
- `RawDeviceWriterTests.testAuthorizeRejectsWhenRawDevicePathDisagreesWithLiveCandidate`
  — same `bsdName` but a different raw device path between the caller's
  selection and the live candidate list must reject, not trust either
  side blindly.

**The safety-critical inventory** — these specific tests are the ones
that must never be weakened or deleted without a deliberate, reviewed
decision, because they're the automated proof behind the two central
findings from Phase 0 (removability alone isn't a safe USB signal;
path-pattern matching alone isn't a safe write-target signal):

| Test | File | Invariant it protects |
|---|---|---|
| `testAuthorizeRejectsInternalBootDiskDespitePatternMatch` | RawDeviceWriterTests | An internal boot disk must never be authorized, even though its path matches the raw-device pattern |
| `testAuthorizeRejectsRemovableNonUSBDevice` | RawDeviceWriterTests | Removable-but-not-USB (e.g. a virtual/simulator volume) must never be authorized |
| `testAuthorizeRejectsSliceNotWholeDisk` | RawDeviceWriterTests | A partition slice must never be authorized, only a whole disk |
| `testAuthorizeRejectsWhenNoLongerInCurrentCandidateList` | RawDeviceWriterTests | A device absent from the *live* candidate list must never be authorized, even from a plausible-looking cached selection |
| `testAuthorizeRejectsWhenRawDevicePathDisagreesWithLiveCandidate` | RawDeviceWriterTests | A `bsdName`/path mismatch between selection and live state must never be authorized |
| `testWriteRoundTripsChecksum` | RawDeviceWriterTests | The write mechanics themselves are lossless (checksum-verified) |
| `testDetectsChecksumMismatch` | MasterReaderTests | A tampered/corrupted drive is detected, not silently trusted |

**Deliberately not attempted here, and shouldn't be**: mocking
`DASession`/`DADisk` to unit-test `USBMonitor`'s event-handling code
path itself (as opposed to the pure `isCandidate` classification logic,
which is what the table above actually exercises) — `DADisk` is an
opaque CoreFoundation type backed by a real disk arbitration session,
and fabricating one convincingly is a project of its own with dubious
payoff versus just testing the classification logic directly, which is
where the actual safety property lives. Also not attempted: hardware-
in-the-loop testing against a real USB drive — that remains a human,
not an agent session, holding physical scratch hardware.

## Phase 9 — packaging scaffolding (stops short of shipping/cutover)

**`Packaging/`** contains what's needed to produce a real, launchable
`.app` for local testing:

- **`Info.plist`** — bundle identifier (`co.uk.voxblock.bookmaster`),
  version, and critically `NSCameraUsageDescription` (the exact key
  Phase 5 found missing).
- **`package-app.sh`** — since SwiftPM doesn't produce `.app` bundles
  natively, this builds a release binary, assembles
  `Contents/{MacOS,Resources}`, carries the SwiftPM-generated resource
  bundle (`config.json`/`books.csv`) across into `Contents/Resources`,
  and ad-hoc signs the result. Run it: `./Packaging/package-app.sh`.
  The produced `.app` is gitignored (a build artifact, not source).

**Camera access confirmed working end-to-end, with a real nuance found
along the way.** Built the actual bundle, then (since I can't click a
system permission dialog myself) wrapped an identical throwaway probe
in the same kind of bundle to test empirically:

- Running the bundled binary **directly** (`Contents/MacOS/BookMaster`
  from a shell) still returns `granted=false` **instantly** — even with
  `Info.plist` correctly bound this time. Turns out the bundle fixes
  necessary-but-not-sufficient: TCC also needs the process launched
  through **LaunchServices** (`open`, or a real double-click), not
  executed directly, to have a WindowServer session capable of showing
  a permission UI at all.
- Launched via `open` instead: **`requestAccess` returned `granted=true`
  in ~2.6 seconds** — a real transition to `.authorized`, not the
  instant permanent `false` from before. Confirms the fix genuinely
  works when the app is actually launched the way a real user would
  launch it.
- Practical takeaway for Phase 1-8's testing pattern of launching the
  built binary directly to check for startup crashes: that's still
  fine for what it was checking (does it crash, does settings.json get
  written), but any *future* TCC-gated capability needs to be verified
  via `open`, not direct execution, or a false "doesn't work" reading
  is possible.

## Not done here, and why — the real gap before this can ship or replace the Python app

None of this happened in this session, deliberately:

- **Developer ID signing.** The bundle above is ad-hoc signed
  (`codesign --sign -`) — fine for local testing, Gatekeeper will block
  it for anyone else. Needs a paid Apple Developer Program membership
  and a real Developer ID Application certificate, neither of which
  exist in this environment.
- **Notarization.** Requires the Developer ID cert above plus
  `notarytool` credentials (an App Store Connect API key or
  Apple ID + app-specific password) submitted to Apple's notary
  service — infrastructure, not code.
- **Bundling and signing `ffmpeg`.** Phase 6 shells out to whatever
  `ffmpeg` it finds on `$PATH`/Homebrew. Shipping this app to someone
  without Homebrew's ffmpeg installed means bundling a real ffmpeg
  binary inside the app and giving it its own valid signature under the
  same Developer ID — not attempted.
- **Entitlements / hardened runtime.** A signed, notarized app
  typically runs under the hardened runtime, which restricts things
  like loading unsigned executable code — the bundled ffmpeg binary
  above would need an explicit entitlement
  (`com.apple.security.cs.allow-unsigned-executable-memory` or similar)
  to keep working under it. Not investigated.
- **A privileged write helper.** Phase 4 deliberately left this
  unsolved — writing to `/dev/rdiskN` needs either the console user
  already having device permissions (untested against real hardware)
  or a proper SMJobBless/XPC helper (needs the signing infrastructure
  above to even build).
- **App icon.** None included — needs a real design asset, not
  something to fabricate here.
- **Sparkle auto-updates.** Needs a real hosted appcast feed and its
  own signing key — infrastructure decision for whoever owns
  distribution, not something to stand up speculatively.
- **Settings/config migration from the Python app.** Still
  deliberately isolated (`~/Library/Application Support/BookMasterSwift/`,
  a bundled `books.csv`/`config.json` snapshot) — see Phase 1's design
  notes. Reconciling with the real production `VoxblockMaster` settings
  and the live `books.csv` is a deliberate decision for whoever owns
  cutover, not a default to fall into.
- **Cutover itself.** This branch does not touch, disable, or replace
  anything in the Python app (`src/`) or `main` in any way. Nothing
  about finishing Phase 9's packaging changes that — moving real users
  onto this requires: real hardware validation of Phases 2 and 4
  (positive-case USB detection, an actual device write) by a human, the
  signing/notarization work above, and an explicit decision from
  whoever owns this product about timing and rollback plan. That
  decision is not made by, and should not be inferred from, this
  branch existing.

## What's deliberately stubbed

- **Batch Create button** still just logs — CSV-driven batch creation
  (looping the pipeline above per ISBN) hasn't been wired up.
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

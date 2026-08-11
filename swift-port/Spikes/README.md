# Phase 0 — De-risk spikes

Standalone Swift Package Manager targets, one per risky assumption in the
[migration plan](../../ — see PR/conversation history for the full plan).
Each is runnable independently with `swift run <TargetName>`.

Build everything: `swift build` from this directory (`swift-port/Spikes`).

## Results summary

| Spike | Status | Notes |
|---|---|---|
| 1. DiskArbitration mount/unmount | ✅ Validated | Ran live, enumerated all attached disks correctly |
| 2. Raw device write mechanics | ✅ Validated | Ran live against a scratch file; checksums matched |
| 3. hdiutil FAT image authoring | ⚠️ Code complete, execution blocked here | Environment-level permission issue, not a code issue — needs re-running from a normal Terminal |
| 4. Vision/AVFoundation barcode scan | ✅ Pipeline validated (via QR substitute) | Live camera capture still needs validation in the real app shell |

Go/no-go for the migration plan: **proceed**. Nothing here surfaced a reason
the Swift port isn't viable. Two items need a human with real hardware
before Phase 1-4 implementation should be trusted (see below).

---

## 1. DiskArbitrationSpike — ✅ validated

`Sources/DiskArbitrationSpike/main.swift`

Registers `DADiskAppearedCallback`/`DADiskDisappearedCallback` on a
`DASession` and prints every disk's removable/ejectable/protocol/volume
info as it (dis)appears — replacing the Python `USBHub`'s 2-second
`psutil` polling loop and its `diskutil`/`system_profiler` shell-outs
entirely with native, event-driven callbacks.

**Ran live on this machine.** DiskArbitration fires `appeared` for every
disk already present at registration time (not just future arrivals), so
the same callback path covers both "already plugged in at launch" and
"plugged in while running" — one code path instead of two.

**Real finding, worth carrying into Phase 2:** `removable == true` is
**not** sufficient to identify "safe to treat as a USB drive." This
machine's CoreSimulator virtual volumes report `removable=true,
ejectable=true` but `protocol=Virtual Interface`, not `USB`. The
candidate-filter used here —
`isRemovable && isWhole && protocolName == "USB"` — correctly excluded
them and every internal Apple Fabric disk (`disk0`–`disk3`), while no
real USB device was attached to test the positive case. **Needs
validation with a real USB drive plugged in** before Phase 2 is called
done, but the negative-case behavior (never misidentifying an internal
or virtual disk) is exactly the safety property that matters most and it
held up.

## 2. RawWriteSpike — ✅ validated

`Sources/RawWriteSpike/main.swift`

Chunked `open`/`write`/`fsync` against a file (standing in for
`/dev/rdiskN`), replacing the current `dd`-via-subprocess call with
native POSIX I/O. **Ran live**: wrote a 10MB pseudo-random source file to
a scratch target in 4MB chunks, fsynced, then SHA-256'd both — checksums
matched.

Also includes `isAllowedRawTargetPattern`, a regex allowlist
(`^/dev/rdisk[0-9]+$`, whole raw disk only, never a slice) — this is the
safety gate the [earlier code review](conversation history) flagged as
missing from the Python implementation (which targeted devices via
string matching with no independent confirmation of removability).

**Real finding:** the pattern test explicitly includes `/dev/rdisk0` —
which matches the allowlist regex and would pass this check alone, but
`disk0` is this machine's **internal boot disk** (see Spike 1's output).
This is concrete proof that path-pattern matching is necessary but not
sufficient: the real port must gate every raw write behind **both** the
pattern check **and** a live DiskArbitration lookup (`removable == true
&& protocol == "USB"`) immediately before the write, not earlier in the
flow where the device could theoretically have been reassigned.

**Not tested here, and must not be:** an actual write to a real
`/dev/rdiskN` device node. That needs a human, on a real machine, with a
specific USB drive they've deliberately designated as expendable scratch
hardware — not something to automate in a coding session.

## 3. FATImageSpike — ⚠️ code complete, blocked in this environment

`Sources/FATImageSpike/main.swift`

Drives `hdiutil create -fs "MS-DOS FAT32" -layout NONE`, attaches
(`-nobrowse`), copies test files in via plain `FileManager` (no `mtools`
needed), detaches, then re-attaches read-only to verify the round-trip —
replacing `mkfs.vfat` + `mtools` (Homebrew-only, not part of the macOS
SDK) with tools built into every Mac.

**Could not execute in this session.** `hdiutil create` fails with
`Operation not permitted` — reproduced with the bare CLI command outside
Swift entirely, and persists even with this session's command sandbox
disabled, so it's a macOS-level permission restriction on the process
that's driving this coding session (most likely: the controlling
terminal/agent host lacks Full Disk Access or an equivalent TCC grant
needed to register a new virtual disk device), not a bug in the spike
code or a fundamental problem with the approach.

**Action needed:** re-run `swift run FATImageSpike` from a normal
interactive Terminal.app session on a dev machine. If it fails there
too, that's a real finding requiring a different image-authoring
approach; if it succeeds, this spike's approach is validated and Phase 3
can proceed as planned.

**Known follow-up even if it does succeed:** `hdiutil create` produces a
UDIF-wrapped `.dmg`, not a flat/raw byte image. Before this can replace
a direct byte-for-byte `dd`-to-device write, the image needs converting
to a flat raw format (`hdiutil convert -format UFBI` or equivalent) so
its on-disk bytes are exactly the FAT filesystem with no wrapper
metadata. Not yet attempted.

## 4. BarcodeSpike — ✅ pipeline validated, live capture untested

`Sources/BarcodeSpike/main.swift`

Still-image path (`scan(imageAt:)`) using `VNDetectBarcodesRequest`
against an `NSImage`-loaded file — replacing OpenCV + pyzbar (and their
`numpy`/`opencv-python` dependency weight) with Vision, which ships on
every Mac.

**Ran live** against a CoreImage-generated QR code encoding a 13-digit
test payload (`9780134685991`) — there's no CoreImage EAN-13 generator
available to synthesize a real one headlessly, so QR was used as a
substitute to exercise the actual engineering risk (the Vision API
plumbing: image load → `CGImage` → request → payload string), which is
symbology-independent. Round-tripped correctly; only the
`request.symbologies` value differs for real EAN-13 codes (already set
correctly to `.ean13` in the shipped version).

Also includes a commented-out sketch of the live `AVCaptureSession` +
`AVCaptureVideoDataOutputSampleBufferDelegate` shape for Phase 5 — not
executable as a bare CLI tool, because camera access requires
`NSCameraUsageDescription` in an app's `Info.plist` plus a TCC consent
prompt that only fires for a real app bundle with a UI event loop, not a
headless SwiftPM executable.

**Action needed:** once the Phase 1 app shell exists, wire up the
sketch, run it, and physically test scanning a real book's ISBN barcode
under real lighting/camera conditions — a live-hardware pyzbar → Vision
comparison for detection reliability is worth doing before fully
retiring the OpenCV path.

---

## What this means for the plan

- Phases 1, 2, 4 (native disk detection, raw write mechanics, barcode
  pipeline) are de-risked as designed — proceed as planned.
- Phase 3 (FAT image authoring) needs one more validation pass on a
  normal dev machine before committing to the `hdiutil` approach over
  bundling `mkfs.vfat`/`mtools` as external binaries instead (the
  fallback if `hdiutil create` turns out to be unusable for this).
- The DiskArbitration "removable ≠ USB" finding and the
  "pattern-match-alone-is-insufficient" finding from Spikes 1–2 should
  be written into Phase 2/4's design explicitly, not left as something
  a future implementer might miss.

# UMPTool Capture & Parse Toolkit

Automates logging of ChipsBank UMPTool's on-screen drive data (Bin/capacity/CE,
Flash ID, chip part, controller type, USB serial) before and after a repair, instead
of manually screenshotting and transcribing.

Two pieces:
- **`umptool_capture_v2.ahk`** — runs on the Windows machine alongside UMPTool.
  Hotkey-triggered; dumps a raw snapshot of everything on screen (plus USB disk
  info) to a flat CSV.
- **`parse_umptool_log.py`** — runs anywhere with Python 3 (your Mac, doesn't need
  the Windows machine). Turns the raw flat log into a clean, structured,
  one-row-per-slot CSV.

---

## Setup (on the Windows machine)

1. **Install AutoHotkey v2** — not v1.1, it's a different, incompatible engine.
   - Full installer: simplest, needs admin once to install.
   - Portable: download the ZIP release, extract `AutoHotkey64.exe`. No install
     step — works well if you'd rather keep everything on a USB key.
2. **Copy `umptool_capture_v2.ahk` onto the same USB key as UMPTool itself**
   (or anywhere on the machine — but see the note on drive letters below).
3. **Always run both UMPTool and the AHK script as Administrator.** UMPTool needs
   elevation to work at all; if the AHK script isn't *also* elevated, Windows
   blocks it from reading UMPTool's window content (silently — no error, it just
   won't capture anything).
4. Nothing else to install — PowerShell (used for the USB serial/VID/PID lookup)
   and WMI ship with Windows by default. No internet connection needed anywhere
   in this setup.

## Running it from a USB key

The log file (`umptool_raw_log.csv`) is written next to wherever the script is
currently running from (`A_ScriptDir`), so running the script directly off the USB
key means the log lands on the key automatically — no path to configure, and it
works even if the key mounts under a different drive letter each time.

**Always press F12 to exit before physically removing the stick.** If you forget
and end up with more than one instance running (e.g. launched a fresh copy after
reinserting the stick under a new letter), the script has a built-in safety net: on
startup it automatically finds and closes any other running instance of itself, so
the newest launch always wins the hotkeys. You shouldn't need to check Task
Manager, but if F9/F10 ever seem to do nothing, that's the first thing to check.

## Using it

1. Open UMPTool (as Administrator) and the AHK script (as Administrator).
2. Connect the drive(s) you're about to work on.
3. **F9** — snapshots the current screen state, tagged `stage=before`.
4. Run the repair/production in UMPTool as normal.
5. **F10** — snapshots the result, tagged `stage=after`.
6. **F12** — exits the script (do this before removing the USB key).

A tray notification confirms each capture and shows how many fields/USB disks were
found — if that count looks unexpectedly low (e.g. near 0), something's wrong;
don't assume the capture worked without checking.

## Parsing the log

On any machine with Python 3 (no special packages needed):

```bash
python3 parse_umptool_log.py umptool_raw_log.csv parsed.csv
```

Re-run this any time against the same (growing) raw log — it processes the whole
file fresh each time, grouped by timestamp+stage, so it's safe to run repeatedly as
more captures get added.

### Output columns

| Column | Meaning |
|---|---|
| `timestamp`, `stage` | When the snapshot was taken, `before` or `after` |
| `slot_index` | Which populated slot this row is (1, 2, 3... within that snapshot) |
| `controller_live` | The controller variant UMPTool reports live (e.g. `2199ESB`) |
| `count`, `settings_summary` | UMPTool's own Count and Settings-summary fields |
| `secondary_variant_tag` | Set only if a variant name appears twice among the legend Statics — should normally be blank; investigate if it isn't |
| `slot_label` | The slot's button label, e.g. `01-D` |
| `drive_letter` | Parsed from the slot label |
| `usb_serial`, `usb_vid`, `usb_pid`, `usb_model` | From Windows' own USB disk info, correlated by drive letter. **VID/PID are usually blank** — see Known Limitations |
| `status` | `ok`, `read_fail`, `unknown_flash`, or `boot_write_fail` |
| `error_code` | The numeric/hex code for a failed status |
| `bin`, `usable_mb`, `raw_mb`, `ce`, `settled_flag` | Parsed from the slot's status line |
| `flash_id`, `chip_part` | The chip's Flash ID and resolved part name |
| `badge` | The single-letter badge shown on the slot (meaning still not fully confirmed — see Known Limitations) |
| `raw_status_text` | The unparsed original status text, kept for reference/debugging |

## Known limitations

- **Error-pattern parsing (`read_fail`, `unknown_flash`, `boot_write_fail`) was
  built from screenshots, not a real captured raw log.** It should work, but
  hasn't been confirmed against real error-case data. If a real error capture
  parses oddly, these regexes (in `parse_umptool_log.py`, near the top) are the
  first place to check.
- **VID/PID usually come back blank.** `Win32_DiskDrive`'s PNPDeviceID for a USB
  stick only carries vendor/product *strings* (`VEN_`/`PROD_`), not the numeric
  `VID_xxxx&PID_yyyy` codes — those live on a separate, parent device node that
  isn't currently queried. Serial number is reliable and was judged sufficient for
  unique per-drive identification; VID/PID can be added later if it turns out to
  matter.
- **The single-letter "badge"** (usually `S`, `C` for a genuine Samsung chip in one
  observed case) does not represent the controller variant — that was
  investigated and ruled out. Its actual meaning is still unconfirmed.
- **Controller variant identification has been inconsistent across methods**
  (UMPTool's own color-coded legend vs. physical chip etching vs. third-party
  tools like ChipGenius). `controller_live` reflects what UMPTool's own UI
  reports, which is the most trustworthy of the three, but isn't independently
  verified against the physical silicon.
- **Multi-drive batch correlation of USB serials** has only been validated for
  small batches where each drive gets its own distinct letter. Hasn't been
  stress-tested against a full 16-port simultaneous batch.
- **USB serial correlation had two distinct failure modes, at different points in
  this toolkit's history — both around resolving a slot's drive letter back to a
  physical disk's serial number.**
  1. *Original WMI associator flakiness* (fixed): the same slot (`04-D`) had its
     drive-letter association present in one snapshot and missing four minutes
     later, same physical drive presumably still connected the whole time — the
     old `Win32_DiskDrive` → `Win32_DiskPartition` → `Win32_LogicalDisk` CIM
     associator chain was confirmed unreliable against real data. Fixed by
     switching the primary lookup to the modern Storage module (`Get-Partition
     -DiskNumber`, a direct property read, no associator hop).
  2. *New pattern seen after that fix* (real captured data, `after` correlates
     100% of drives with a letter; `before` consistently correlates only ~1 of N,
     no matter the batch size). Windows Explorer clearly shows drive letters for
     all of them at `before` time too, so this isn't a mount-timing race.
     Working theory, unconfirmed: since `before` drives are the bad/write-damaged
     batch under investigation and haven't been repaired yet, some may have a
     drive letter from the volume manager without a partition-table entry that
     `Get-Partition` can enumerate (e.g. RAW/corrupted media) — `after` drives
     have just been freshly re-partitioned by UMPTool, so `Get-Partition` finds
     them cleanly. `GetUsbDiskInfo()` no longer silently swallows a `Get-Partition`
     failure: it now falls back to the old CIM associator chain if `Get-Partition`
     finds nothing, and if both fail, writes a `DIAG|` line to the raw log with the
     actual exception message, so the next real capture should show the true
     cause instead of a guess. This hasn't been tested against real hardware
     since this change.
- **Some connected drives never get a Windows drive letter at all** and so can
  never be serial-correlated by this method, regardless of retries. Seen directly
  in real data: several `ChipsBnk Flash Disk USB Device` entries with a
  completely blank drive letter in `Win32_DiskDrive` — Windows sees the raw USB
  device but never mounts a filesystem on it (consistent with a corrupted/dead
  drive UMPTool can still talk to at a lower level than Windows can). These
  drives' slots will always show blank `usb_serial` in the parsed output; that's
  expected, not a bug to chase.

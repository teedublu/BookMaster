#!/usr/bin/env python3
"""
Parses the raw tab-separated log written by umptool_capture_v2.ahk into a
structured, one-row-per-slot CSV.

Usage: python3 parse_umptool_log.py umptool_raw_log.csv umptool_parsed.csv
"""
import csv
import re
import sys
from collections import defaultdict

LEGEND_NAMES = {"2199EB", "2199S", "2199EST", "2199ES", "2199ESB", "2199EE", "Other"}

STATUS_RE = re.compile(
    r'Bin(\d+),\s*(\d+)M(?:\((\d+)M\))?,CE:(\d+)(?:\s*\[(\w)\])?'
)
# Known error patterns seen during this investigation. NOT yet validated against a
# real captured error row (only screenshots) - if a real capture parses oddly for
# an error slot, these patterns are the first place to check/adjust.
READ_FAIL_RE = re.compile(r'Read Flash infomation fail\.?\((\w+)\)', re.IGNORECASE)
UNKNOWN_FLASH_RE = re.compile(r'UNKNOWN_FLASH,\s*CE:(\d+)\s*\((\w+)\)')
BOOT_WRITE_FAIL_RE = re.compile(r'Write boot page error\.?\((\w+)\)', re.IGNORECASE)
# Slot button labels look like "01", "04-D", or (once a slot has been actively
# tracked - confirmed in a real "after" capture) with an elapsed-time suffix like
# "01-H | 0:0:23". The trailing time part is optional and stripped, not captured.
SLOT_LABEL_RE = re.compile(r'^(\d{2})(-([A-Za-z]))?(\s*\|\s*\d+:\d+:\d+)?$')
# Eject Info's own text is prefixed with a slot label ("01-D, Bin7, ..."), unlike a
# slot's own live status text which has no such prefix - used only to recognize and
# skip it now that we're not extracting its fields anymore.
EJECT_INFO_PREFIX_RE = re.compile(r'^\d{2}-[A-Za-z],')

FIELDNAMES = [
    "timestamp", "stage", "slot_index",
    "controller_live", "count", "settings_summary",
    "secondary_variant_tag",
    "slot_label", "drive_letter",
    "usb_serial", "usb_vid", "usb_pid", "usb_model",
    "status", "error_code",
    "bin", "usable_mb", "raw_mb", "ce", "settled_flag",
    "flash_id", "chip_part", "badge", "raw_status_text",
]


def new_slot_from_text(txt):
    """Return a fresh slot dict if txt starts a new slot (success or known error
    pattern), else None. Order matters: check error patterns before the general
    Bin-success pattern since they don't overlap in practice but keeps intent clear."""
    m = UNKNOWN_FLASH_RE.search(txt)
    if m:
        return {"status": "unknown_flash", "error_code": m.group(2),
                "bin": "", "usable_mb": "", "raw_mb": "", "ce": m.group(1),
                "settled_flag": "", "raw_status_text": txt,
                "flash_id": "", "chip_part": "", "badge": "",
                "slot_label": "", "drive_letter": ""}

    m = READ_FAIL_RE.search(txt)
    if m:
        return {"status": "read_fail", "error_code": m.group(1),
                "bin": "", "usable_mb": "", "raw_mb": "", "ce": "",
                "settled_flag": "", "raw_status_text": txt,
                "flash_id": "", "chip_part": "", "badge": "",
                "slot_label": "", "drive_letter": ""}

    m = BOOT_WRITE_FAIL_RE.search(txt)
    if m:
        return {"status": "boot_write_fail", "error_code": m.group(1),
                "bin": "", "usable_mb": "", "raw_mb": "", "ce": "",
                "settled_flag": "", "raw_status_text": txt,
                "flash_id": "", "chip_part": "", "badge": "",
                "slot_label": "", "drive_letter": ""}

    m = STATUS_RE.search(txt)
    if m and not txt.startswith("ID:"):
        return {"status": "ok", "error_code": "",
                "bin": m.group(1), "usable_mb": m.group(2), "raw_mb": m.group(3) or "",
                "ce": m.group(4), "settled_flag": m.group(5) or "",
                "raw_status_text": txt, "flash_id": "", "chip_part": "", "badge": "",
                "slot_label": "", "drive_letter": ""}

    return None


def parse_snapshot(items):
    controller_live = ""
    count = ""
    settings_summary = ""
    secondary_variant_tag = ""
    legend_assigned = set()

    slots = []
    current_slot = None
    pending_slot_label = ""
    pending_drive_letter = ""
    usb_disk_info = {}  # drive_letter -> {serial, vid, pid, model}

    for it in items:
        cls = it["class"]
        txt = it["text"].strip()

        if cls == "USB_DISK_INFO":
            parts = txt.split("|")
            # Diagnostic lines from the PowerShell side (an error, or "no disks at all")
            if parts and parts[0] in ("ERROR", "INFO", "DIAG"):
                usb_disk_info.setdefault("__diagnostic__", []).append(txt)
                continue
            if len(parts) >= 7:
                drive_letter, serial, vid, pid, model, interface_type, pnp_id = parts[:7]
                # InterfaceType alone is unreliable (plenty of USB mass storage reports
                # as SCSI) - PNPDeviceID reliably starts with USBSTOR/USB for real USB disks.
                is_usb_like = (
                    interface_type.strip().upper() == "USB"
                    or "USBSTOR" in pnp_id.upper()
                    or pnp_id.upper().startswith("USB")
                )
                if drive_letter and is_usb_like:
                    usb_disk_info[drive_letter.upper()] = {
                        "usb_serial": serial, "usb_vid": vid,
                        "usb_pid": pid, "usb_model": model,
                    }
            continue

        if txt == "" or txt.startswith("Progress"):
            continue

        if cls == "Button":
            m = SLOT_LABEL_RE.match(txt)
            if m:
                pending_slot_label = (m.group(1) + ("-" + m.group(3) if m.group(3) else ""))
                pending_drive_letter = m.group(3) or ""
            continue

        # Legend labels vs the one live-value Edit control that happens to share
        # a variant name string. First 7 unique variant-name Statics = legend;
        # anything beyond that count, or any Edit match, is a real value.
        if txt in LEGEND_NAMES:
            if cls == "Edit" and controller_live == "":
                controller_live = txt
                continue
            if cls == "Static":
                if txt not in legend_assigned:
                    legend_assigned.add(txt)
                    continue
                else:
                    # a genuine repeat of a variant name already claimed by the legend
                    secondary_variant_tag = txt
                    continue

        if cls == "Edit" and re.fullmatch(r"\d+", txt) and count == "":
            count = txt
            continue

        if cls == "Edit" and "scan" in txt.lower() and settings_summary == "":
            settings_summary = txt
            continue

        if cls == "Edit" and EJECT_INFO_PREFIX_RE.match(txt):
            continue

        if cls in ("Edit", "msctls_progress32"):
            new_slot = new_slot_from_text(txt)
            if new_slot:
                if current_slot:
                    slots.append(current_slot)
                new_slot["slot_label"] = pending_slot_label
                new_slot["drive_letter"] = pending_drive_letter
                pending_slot_label = ""
                pending_drive_letter = ""
                current_slot = new_slot
                continue

        if cls == "Edit" and txt.startswith("ID:") and current_slot is not None:
            current_slot["flash_id"] = txt[3:]
            continue

        if (cls == "Edit" and current_slot is not None
                and current_slot["chip_part"] == ""
                and re.match(r"^[A-Za-z0-9]", txt)
                and "CE:" not in txt and not txt.startswith("ID:")):
            current_slot["chip_part"] = txt
            continue

        if (cls == "msctls_progress32" and current_slot is not None
                and current_slot["badge"] == "" and len(txt) <= 2):
            current_slot["badge"] = txt
            continue

    if current_slot:
        slots.append(current_slot)

    # attach USB disk info (serial/VID/PID/model) to each slot by drive letter
    for s in slots:
        info = usb_disk_info.get(s["drive_letter"].upper(), {}) if s["drive_letter"] else {}
        s["usb_serial"] = info.get("usb_serial", "")
        s["usb_vid"] = info.get("usb_vid", "")
        s["usb_pid"] = info.get("usb_pid", "")
        s["usb_model"] = info.get("usb_model", "")

    diagnostics = usb_disk_info.get("__diagnostic__", [])
    return controller_live, count, settings_summary, secondary_variant_tag, slots, diagnostics


def main(input_path, output_path):
    with open(input_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows = [r for r in reader if r.get("timestamp")]

    snapshots = defaultdict(list)
    for r in rows:
        snapshots[(r["timestamp"], r["stage"])].append(r)

    out_rows = []
    for (ts, stage), items in snapshots.items():
        controller_live, count, settings_summary, secondary_variant_tag, slots, diagnostics = parse_snapshot(items)
        for d in diagnostics:
            print(f"[{ts} {stage}] USB disk query diagnostic: {d}")

        base = {
            "timestamp": ts, "stage": stage,
            "controller_live": controller_live, "count": count,
            "settings_summary": settings_summary,
            "secondary_variant_tag": secondary_variant_tag,
        }

        if not slots:
            out_rows.append({**base, "slot_index": "", "slot_label": "", "drive_letter": "",
                              "usb_serial": "", "usb_vid": "", "usb_pid": "", "usb_model": "",
                              "status": "", "error_code": "",
                              "bin": "", "usable_mb": "", "raw_mb": "", "ce": "",
                              "settled_flag": "", "flash_id": "", "chip_part": "",
                              "badge": "", "raw_status_text": ""})
        else:
            for i, s in enumerate(slots, 1):
                out_rows.append({**base, "slot_index": i, **s})

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(out_rows)

    print(f"Wrote {len(out_rows)} row(s) to {output_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 parse_umptool_log.py <raw_log.csv> <output.csv>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])

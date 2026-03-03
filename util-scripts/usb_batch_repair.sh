#!/usr/bin/env bash
set -euo pipefail

# usb_batch_repair.sh
# - Checks system_profiler SPUSBDataType for "UDisk" devices (USB-visible)
# - Checks diskutil for external removable USB disks (disk-visible)
# - Optionally wipes first 50MB and re-partitions as FAT32 MBR

EXECUTE=0
LABEL="VOXBLOCK"
MAX_GB=2          # safety guard: only touch disks <= this size (GB). set higher if needed
ZERO_MB=50        # how much to wipe from the start of disk
LOGFILE="./usb_batch_repair_$(date +%Y%m%d_%H%M%S).log"

usage() {
  cat <<EOF
Usage: $0 [--execute] [--label NAME] [--max-gb N] [--zero-mb N] [--log PATH]

Defaults:
  --execute      : OFF (dry-run)
  --label        : ${LABEL}
  --max-gb       : ${MAX_GB}
  --zero-mb      : ${ZERO_MB}
  --log          : ${LOGFILE}

Examples:
  $0
  $0 --execute
  $0 --execute --label VOX --max-gb 8 --zero-mb 100
EOF
}

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE" >&2
}

require_sudo_if_execute() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    if [[ "$EUID" -ne 0 ]]; then
      log "Execute mode requires sudo. Re-running with sudo..."
      exec sudo -E bash "$0" "$@"
    fi
  fi
}

# Pretty-print: list UDisk-ish USB devices from system_profiler
list_usb_devices_profiler() {
  log "Scanning USB devices via system_profiler (this can take a few seconds)..."
  local out
  out="$(system_profiler SPUSBDataType 2>/dev/null || true)"

  # Pull blocks that contain "UDisk" (or tweak this grep if your product string differs)
  # We print Product ID, Vendor ID, Serial Number, Location ID, Speed.
  echo "$out" | awk '
    BEGIN { inblk=0; }
    /UDisk/ { inblk=1; print "---- USB Device (system_profiler) ----"; print $0; next }
    inblk==1 {
      if ($0 ~ /^[[:space:]]*$/) { inblk=0; print ""; next }
      if ($0 ~ /Product ID:|Vendor ID:|Serial Number:|Location ID:|Speed:|Manufacturer:/) print $0
    }
  ' | tee -a "$LOGFILE" >&2

  log "Done scanning system_profiler."
}

# Get candidate disks from diskutil list: external + whole disks only
# Then filter further with diskutil info.
get_candidate_disks() {
  # Find /dev/diskN lines from diskutil list
  diskutil list | awk '/^\/dev\/disk[0-9]+/ { gsub(":", "", $1); print $1 }'
}

# Parse "diskutil info" output for fields we need
disk_info_field() {
  local disk="$1"
  local field="$2"
  diskutil info "$disk" 2>/dev/null | awk -F: -v f="$field" '
    $1 ~ f { sub(/^[[:space:]]+/, "", $2); print $2; exit }
  '
}

# Convert "1.0 GB" or "999.9 MB" into GB float-ish (best effort)
to_gb() {
  local s="$1"
  # Expect something like "1.0 GB" or "1000.0 MB"
  local num unit
  num="$(echo "$s" | awk '{print $1}')"
  unit="$(echo "$s" | awk '{print $2}')"
  if [[ "$unit" == "GB" ]]; then
    echo "$num"
  elif [[ "$unit" == "MB" ]]; then
    awk -v n="$num" 'BEGIN { printf "%.4f\n", n/1024 }'
  else
    # Unknown format
    echo "9999"
  fi
}

is_safe_candidate() {
  local disk="$1"

  local internal protocol removable size_str
  internal="$(disk_info_field "$disk" "Device Location")" || internal=""
  protocol="$(disk_info_field "$disk" "Protocol")" || protocol=""
  removable="$(disk_info_field "$disk" "Removable Media")" || removable=""
  size_str="$(disk_info_field "$disk" "Disk Size")" || size_str=""

  # Must be external + USB + removable
  [[ "$internal" == "External" ]] || return 1
  [[ "$protocol" == "USB" ]] || return 1
  [[ "$removable" == "Removable" ]] || return 1

  # Size guard
  local gb
  gb="$(to_gb "$size_str")"
  awk -v g="$gb" -v max="$MAX_GB" 'BEGIN { exit (g <= max) ? 0 : 1 }' || return 1

  return 0
}

repair_disk() {
  local disk="$1"
  local rdisk="${disk/\/dev\/disk/\/dev\/rdisk}"

  log "Candidate: $disk"
  log "  Name:        $(disk_info_field "$disk" "Device / Media Name" || true)"
  log "  Disk Size:   $(disk_info_field "$disk" "Disk Size" || true)"
  log "  Protocol:    $(disk_info_field "$disk" "Protocol" || true)"
  log "  Location:    $(disk_info_field "$disk" "Device Location" || true)"
  log "  Removable:   $(disk_info_field "$disk" "Removable Media" || true)"
  log "  Read-Only:   $(disk_info_field "$disk" "Media Read-Only" || true)"

  if [[ "$EXECUTE" -eq 0 ]]; then
    log "DRY RUN: would run:"
    log "  diskutil unmountDisk force $disk"
    log "  dd if=/dev/zero of=$rdisk bs=1m count=$ZERO_MB"
    log "  diskutil eraseDisk FAT32 $LABEL MBRFormat $disk"
    return 0
  fi

  log "EXECUTE: unmounting..."
  diskutil unmountDisk force "$disk" | tee -a "$LOGFILE" >&2 || true

  log "EXECUTE: zeroing first ${ZERO_MB}MB on $rdisk ..."
  # Use rdisk for speed; add status=progress for visibility.
  dd if=/dev/zero of="$rdisk" bs=1m count="$ZERO_MB" status=progress 2>&1 | tee -a "$LOGFILE" >&2

  log "EXECUTE: erasing disk as FAT32 (MBR) with label '$LABEL' ..."
  diskutil eraseDisk FAT32 "$LABEL" MBRFormat "$disk" 2>&1 | tee -a "$LOGFILE" >&2

  log "SUCCESS: $disk repaired (if the controller allows writes)."
}

main() {
  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute) EXECUTE=1; shift ;;
      --label) LABEL="$2"; shift 2 ;;
      --max-gb) MAX_GB="$2"; shift 2 ;;
      --zero-mb) ZERO_MB="$2"; shift 2 ;;
      --log) LOGFILE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  require_sudo_if_execute "$@"

  log "Starting. Mode: $([[ "$EXECUTE" -eq 1 ]] && echo EXECUTE || echo DRY-RUN)"
  log "Log: $LOGFILE"
  log "Safety guard: only External+USB+Removable disks <= ${MAX_GB}GB will be touched."

  list_usb_devices_profiler

  log "Scanning diskutil for external removable USB disks..."
  local disks=()
  while IFS= read -r d; do
    disks+=("$d")
  done < <(get_candidate_disks)

  local found=0
  for d in "${disks[@]}"; do
    if is_safe_candidate "$d"; then
      found=1
      repair_disk "$d"
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log "No safe candidate disks found in diskutil."
    log "If you saw UDisk in system_profiler but nothing in diskutil, those are firmware/FTL-bricked and not repairable via macOS."
  fi

  log "Done."
}

main "$@"

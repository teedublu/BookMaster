#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <source_dir> <last5_isbn> [disk_id]" >&2
  echo "  <source_dir>  Root folder containing the book directories" >&2
  echo "  <last5_isbn>  Last 5 digits of the ISBN (e.g. 12345)" >&2
  echo "  [disk_id]     Optional, e.g. /dev/disk4. If omitted, script" >&2
  echo "                will try to auto-detect a single external disk." >&2
  exit 1
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
fi

SOURCE_DIR="$1"
ISBN_LAST5="$2"
DISK_ID="${3:-}"


# --- Basic checks ---
if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: Source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if [[ ! "$ISBN_LAST5" =~ ^[0-9]{5}$ ]]; then
  echo "ERROR: last5_isbn must be exactly 5 digits (got '$ISBN_LAST5')." >&2
  exit 1
fi

echo "Looking for book directory matching: BK-${ISBN_LAST5}-* under:"
echo "  $SOURCE_DIR"
echo

# Speed up globbing: unmatched patterns expand to nothing
shopt -s nullglob

get_used_mib_from_img() {
  local img="$1"
  local mp used_kib used_mib
  mp="$(hdiutil attach -readonly -nobrowse -owners off "$img" 2>/dev/null | awk '/\/Volumes\// {print $NF; exit}')"
  if [ -z "$mp" ]; then
    echo "ERROR: Could not mount image to compute used size: $img" >&2
    return 1
  fi

  used_kib="$(df -k "$mp" | awk 'NR==2 {print $3}')"
  used_mib="$(awk "BEGIN {printf \"%.1f\", $used_kib/1024}")"

  hdiutil detach "$mp" >/dev/null 2>&1 || hdiutil detach -force "$mp" >/dev/null 2>&1 || true
  echo "$used_mib"
}


# --- Find book directory using BK-<last5>-* pattern ---
book_candidates=( "$SOURCE_DIR"/BK-"$ISBN_LAST5"-* )

if [ "${#book_candidates[@]}" -eq 0 ]; then
  echo "ERROR: No book directory found matching:" >&2
  echo "       $SOURCE_DIR/BK-${ISBN_LAST5}-*" >&2
  exit 1
elif [ "${#book_candidates[@]}" -gt 1 ]; then
  echo "ERROR: Multiple book directories found:" >&2
  printf '  %s\n' "${book_candidates[@]}" >&2
  echo "Clean up duplicates or be more specific." >&2
  exit 1
fi

BOOK_DIR="${book_candidates[0]}"

if [ ! -d "$BOOK_DIR" ]; then
  echo "ERROR: Matched book path is not a directory: $BOOK_DIR" >&2
  exit 1
fi

echo "Book directory:"
echo "  $BOOK_DIR"
echo

# --- Find image file inside book_dir/image ---
image_dir="$BOOK_DIR/image"

if [ ! -d "$image_dir" ]; then
  echo "ERROR: image/ directory not found under book dir:" >&2
  echo "       $image_dir" >&2
  exit 1
fi

img_candidates=( "$image_dir"/BK-"$ISBN_LAST5"-*.img )

if [ "${#img_candidates[@]}" -eq 0 ]; then
  echo "ERROR: No .img file found matching:" >&2
  echo "       $image_dir/BK-${ISBN_LAST5}-*.img" >&2
  exit 1
elif [ "${#img_candidates[@]}" -gt 1 ]; then
  echo "ERROR: Multiple .img files found:" >&2
  printf '  %s\n' "${img_candidates[@]}" >&2
  echo "Clean up duplicates." >&2
  exit 1
fi

IMG_FILE="${img_candidates[0]}"
SKU_FILENAME="$(basename "$IMG_FILE")"
SKU="${SKU_FILENAME%.img}"

# Image size (bytes and MB) – macOS stat
IMG_SIZE_BYTES=$(stat -f%z "$IMG_FILE")
USED_MIB="$(get_used_mib_from_img "$IMG_FILE")"
IMG_SIZE_MIB=$(awk "BEGIN {printf \"%.1f\", $IMG_SIZE_BYTES/1024/1024}")
IMAGE_MIB="$IMG_SIZE_MIB"


echo "Selected image:"
echo "  SKU filename:   $SKU_FILENAME"
echo "  SKU (no .img):  $SKU"
echo "  Book directory: $BOOK_DIR"
echo "  Image path:     $IMG_FILE"
echo "  Image size:     ${IMG_SIZE_MIB} MiB"
echo

# --- Determine target disk ---
if [ -z "$DISK_ID" ]; then
  echo "Detecting external physical disks via diskutil..."
  disks=()
  while IFS= read -r d; do
    [ -n "$d" ] && disks+=( "$d" )
  done < <(diskutil list external physical | awk '/^\/dev\// {print $1}')

  if [ "${#disks[@]}" -eq 0 ]; then
    echo "ERROR: No external physical disks found." >&2
    echo "Plug in the USB drive and try again, or pass disk_id explicitly." >&2
    exit 1
  elif [ "${#disks[@]}" -gt 1 ]; then
    echo "ERROR: More than one external physical disk detected:" >&2
    printf '  %s\n' "${disks[@]}" >&2
    echo "Specify which one to use: $0 \"$SOURCE_DIR\" \"$ISBN_LAST5\" /dev/diskX" >&2
    exit 1
  fi

  DISK_ID="${disks[0]}"
fi

# Normalise disk id (allow 'disk4' or '/dev/disk4')
if [[ "$DISK_ID" != /dev/* ]]; then
  DISK_ID="/dev/$DISK_ID"
fi

RAW_DISK="/dev/r${DISK_ID#/dev/}"

echo "Target disk:"
echo "  Block device: $DISK_ID"
echo "  Raw device:   $RAW_DISK"
echo
echo "WARNING: This will ERASE and overwrite the entire disk."
echo "  SKU:   $SKU"
echo "  Image: $IMG_FILE"
echo
read -r -p "Hit 'RET' to continue 'NO' to abort: " CONFIRM

if [ "$CONFIRM" == "NO" ]; then
  echo "Aborted."
  exit 1
fi

echo
echo "Unmounting $DISK_ID (force)..."
if ! sudo diskutil unmountDisk force "$DISK_ID"; then
  echo "Warning: unmountDisk force failed (likely Spotlight). Continuing anyway."
fi


echo
echo
echo "Writing image with pv + dd..."
echo "This may take a while depending on USB speed and image size."
echo

start_time=$(date +%s)

# Use a larger block size for better throughput on macOS
BLOCK_SIZE=4m

pv "$IMG_FILE" | sudo dd of="$RAW_DISK" bs=$BLOCK_SIZE status=none

end_time=$(date +%s)
elapsed=$(( end_time - start_time ))
[ "$elapsed" -le 0 ] && elapsed=1  # avoid divide-by-zero

SPEED_MB_S=$(awk "BEGIN {printf \"%.2f\", $IMG_SIZE_BYTES/1024/1024/$elapsed}")
THROUGHPUT_USED_MIB_S=$(awk "BEGIN {printf \"%.2f\", $USED_MIB/$elapsed}")
THROUGHPUT_IMAGE_MIB_S=$(awk "BEGIN {printf \"%.2f\", $IMG_SIZE_BYTES/1024/1024/$elapsed}")


echo
echo "Syncing..."
sync

echo
echo "Mounting volumes on $DISK_ID to count tracks on the USB..."
disk_id_short="${DISK_ID#/dev/}"

# Collect child partition identifiers, e.g. disk4s1, disk4s2
child_ids=()
while IFS= read -r id; do
  [ -n "$id" ] && child_ids+=( "$id" )
done < <(diskutil list "$disk_id_short" | awk '/^[[:space:]]*[0-9]+:/ {print $NF}')

TRACKS_MOUNT=""
TRACK_COUNT=0

for cid in "${child_ids[@]}"; do
  # Mount partition; ignore errors (e.g. already mounted)
  diskutil mount "$cid" >/dev/null 2>&1 || true

  mp=$(diskutil info "$cid" | awk -F: '/Mount Point/ {sub(/^ +/, "", $2); print $2}')
  if [ -n "$mp" ] && [ -d "$mp/tracks" ]; then
    TRACKS_MOUNT="$mp/tracks"
    TRACK_COUNT=$(find "$TRACKS_MOUNT" -type f 2>/dev/null | wc -l | awk '{print $1}')
    break
  fi
done

# --- Extract VID / PID / Serial from ioreg for selected disk ---
get_usb_meta_by_ioreg() {
  local disk_node="$1"
  /usr/bin/python3 - "$disk_node" <<'PY'
import plistlib
import re
import subprocess
import sys

disk_node = sys.argv[1]

def read_diskutil_plist(node: str):
    try:
        out = subprocess.check_output(
            ["/usr/sbin/diskutil", "info", "-plist", node],
            stderr=subprocess.DEVNULL,
        )
        return plistlib.loads(out)
    except Exception:
        return {}

def parse_location_hex(di: dict):
    candidates = [
        di.get("IORegistryEntryPath"),
        di.get("IODeviceTreePath"),
        di.get("DeviceTreePath"),
        di.get("IORegistryEntryName"),
    ]
    for c in candidates:
        if not c:
            continue
        m = re.search(r'@([0-9A-Fa-f]+)\b', str(c))
        if m:
            return m.group(1)
    return None

def find_block_for_location(ioreg_text: str, location_dec: int):
    for block in ioreg_text.split("+-o "):
        m = re.search(r'"locationID"\s*=\s*(\d+)', block)
        if m and int(m.group(1)) == location_dec:
            return block
    return ""

def parse_first(pattern: str, text: str) -> str:
    m = re.search(pattern, text, flags=re.IGNORECASE)
    return (m.group(1).strip() if m else "")

di = read_diskutil_plist(disk_node)
loc_hex = parse_location_hex(di)
if not loc_hex:
    print("\t\t")
    raise SystemExit(0)

try:
    loc_dec = int(loc_hex, 16)
except ValueError:
    print("\t\t")
    raise SystemExit(0)

try:
    ioreg_text = subprocess.check_output(
        ["/usr/sbin/ioreg", "-p", "IOUSB", "-l", "-w", "0"],
        stderr=subprocess.DEVNULL,
    ).decode("utf-8", "replace")
except Exception:
    print("\t\t")
    raise SystemExit(0)

blk = find_block_for_location(ioreg_text, loc_dec)
if not blk:
    print("\t\t")
    raise SystemExit(0)

serial = parse_first(r'"USB Serial Number"\s*=\s*"([^"]+)"', blk)
vid_dec = parse_first(r'"idVendor"\s*=\s*(\d+)', blk)
pid_dec = parse_first(r'"idProduct"\s*=\s*(\d+)', blk)

vid = (f"{int(vid_dec):04X}" if vid_dec.isdigit() else "")
pid = (f"{int(pid_dec):04X}" if pid_dec.isdigit() else "")

print(f"{vid}\t{pid}\t{serial}")
PY
}

IFS=$'\t' read -r VID PID SERIAL < <(get_usb_meta_by_ioreg "$DISK_ID")

VID=${VID:-UNKNOWN}
PID=${PID:-UNKNOWN}
SERIAL=${SERIAL:-UNKNOWN}

echo "USB metadata:"
echo "  VID:    $VID"
echo "  PID:    $PID"
echo "  Serial: $SERIAL"
echo



echo
if [ -z "$TRACKS_MOUNT" ]; then
  echo "WARNING: No /tracks directory found on any mounted volume for $DISK_ID."
else
  echo "Tracks directory on USB: $TRACKS_MOUNT"
  echo "Track file count on USB: $TRACK_COUNT"
fi

echo "Unmounting all partitions for $DISK_ID..."
for cid in "${child_ids[@]}"; do
  sudo diskutil unmount "$cid" >/dev/null 2>&1 || true
done

echo "Ejecting $DISK_ID..."
sudo diskutil eject "$DISK_ID" || {
  echo "Eject failed, forcing unmount of whole disk..."
  sudo diskutil unmountDisk force "$DISK_ID" || true
}

# --- Compute approximate duration from image size (96 kbps assumed) ---
IMG_SIZE_BYTES_CALC=$(awk "BEGIN {printf \"%0.f\", $IMG_SIZE_MIB * 1024 * 1024}")

TOTAL_BITS=$(( IMG_SIZE_BYTES_CALC * 8 ))

RAW_SECONDS=$(awk "BEGIN {printf \"%0.0f\", $TOTAL_BITS / 96000}")

# Convert to hh:mm:ss style
MINUTES=$((RAW_SECONDS / 60))
SECONDS=$((RAW_SECONDS % 60))
HOURS=$((MINUTES / 60))
HM_MINUTES=$((MINUTES % 60))

if [ "$HOURS" -gt 0 ]; then
  IMG_DURATION="${HOURS}h ${HM_MINUTES}m"
else
  IMG_DURATION="${MINUTES}m ${SECONDS}s"
fi




# --- Append successful write to CSV log ---
LOG_FILE="masterwrite_log.csv"

# Create header if file doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  echo "timestamp,sku,used_mib_1dp,image_mib_1dp,duration,track_count,elapsed_s,throughput_used_mib_s,throughput_image_mib_s,vid,pid,serial,disk_id,image_file,book_dir" >> "$LOG_FILE"
fi

TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "${TIMESTAMP},${SKU},${USED_MIB},${IMAGE_MIB},\"${IMG_DURATION}\",${TRACK_COUNT},${elapsed},${THROUGHPUT_USED_MIB_S},${THROUGHPUT_IMAGE_MIB_S},${VID},${PID},${SERIAL},${DISK_ID},\"${IMG_FILE}\",\"${BOOK_DIR}\"" >> "$LOG_FILE"



echo
echo "Done."
echo
echo "Summary:"
echo "  Image:                $IMG_FILE"
echo "  Book directory:       $BOOK_DIR"
if [ -n "$TRACKS_MOUNT" ]; then
echo "  USB tracks directory: $TRACKS_MOUNT"
echo "  Track file count:     $TRACK_COUNT"
else
echo "  USB tracks directory: (not found)"
fi
echo "  SKU:                  $SKU"
echo "  Used size (join key): ${USED_MIB} MiB"
echo "  Image size:           ${IMAGE_MIB} MiB"
echo "  Throughput (used):    ${THROUGHPUT_USED_MIB_S} MiB/s"
echo "  Throughput (image):   ${THROUGHPUT_IMAGE_MIB_S} MiB/s"

echo "  Duration expected:    ${IMG_DURATION}"



# bm_registry_gsheet.py
import os, math, time, shlex, subprocess, tempfile
from typing import Dict, Optional, Set, Tuple

import gspread

# =================== Config ===================

SHEET_ID  = os.environ["BOOKMASTER_SHEET_ID"]
TAB_NAME  = "image_registry"
HEADER    = [
    "timestamp_utc","sku","image_path",
    "used_bytes","used_mib","used_mib_1dp",
    "total_bytes","total_mib","total_mib_1dp",
    "volume_label","file_size_bytes",
]

# optional kill-switch to skip watermarking entirely (for triage)
SKIP_WATERMARK = os.environ.get("BM_SKIP_WATERMARK") == "1"

# =================== Sheets helpers ===================

_WKS = None
_OCC_CACHE: Optional[Set[str]] = None
_OCC_CACHE_AT: float = 0.0
_OCC_TTL = 15  # seconds

def _gc() -> gspread.Client:
    gc = gspread.service_account(filename=os.environ["GOOGLE_APPLICATION_CREDENTIALS"])
    gc.set_timeout(10)  # seconds
    return gc

def _wks():
    global _WKS
    if _WKS is None:
        sh = _gc().open_by_key(SHEET_ID)
        _WKS = sh.worksheet(TAB_NAME)
    return _WKS

def ensure_header():
    wks = _wks()
    head = wks.row_values(1)
    if head != HEADER:
        wks.update("A1", [HEADER])

def append_row(row: Dict[str, str]):
    wks = _wks()
    wks.append_row([str(row.get(h, "")) for h in HEADER], value_input_option="RAW")

def _coerce_1dp_str(v) -> Optional[str]:
    s = str(v).strip()
    if not s:
        return None
    try:
        f = float(s)
    except ValueError:
        return None
    # half-up to one decimal place
    return f"{(math.floor(f*10 + 0.5)/10.0):.1f}"

def get_occupied_slots_1dp(force_refresh: bool = False) -> Set[str]:
    """
    Return {'59.4','60.6',...} from column F (used_mib_1dp).
    Cached to avoid repeated calls within one run.
    """
    global _OCC_CACHE, _OCC_CACHE_AT
    now = time.time()
    if (not force_refresh) and _OCC_CACHE is not None and (now - _OCC_CACHE_AT) < _OCC_TTL:
        return _OCC_CACHE
    col = _wks().col_values(6)[1:]  # F2:F
    occ = {s for s in (_coerce_1dp_str(v) for v in col) if s}
    _OCC_CACHE, _OCC_CACHE_AT = occ, now
    return occ

def find_sku_row(sku: str) -> Tuple[Optional[int], Optional[float]]:
    """
    Return (row_index, recorded_used_mib_1dp) for existing SKU, or (None, None) if not found.
    Row index is 1-based; data starts at row 2.
    """
    wks = _wks()
    skus = wks.col_values(2)  # column B (sku), including header
    for idx, val in enumerate(skus[1:], start=2):
        if val.strip() == sku:
            used_1dp_str = _coerce_1dp_str(wks.cell(idx, 6).value)  # F
            return idx, (float(used_1dp_str) if used_1dp_str else None)
    return None, None

# =================== mtools + measurement ===================

def _run(cmd: str, timeout: float = 5.0) -> str:
    """
    Run a shell command with neutral C locale and hard timeout.
    """
    env = {**os.environ, "LC_ALL": "C", "LANG": "C"}
    try:
        p = subprocess.run(
            shlex.split(cmd),
            capture_output=True,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Command timed out after {timeout}s: {cmd}")
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace") if p.stderr else ""
        raise RuntimeError(f"Command failed: {cmd}\n{err}")
    return p.stdout.decode("utf-8", "replace") if p.stdout else ""

def _round_1dp_half_up(x: float) -> float:
    return math.floor(x * 10 + 0.5) / 10.0

def _mdir_free_bytes(image_path: str) -> Optional[int]:
    out = _run(f'mdir -i "{image_path}" ::')
    for ln in reversed(out.splitlines()):
        if "bytes free" in ln:
            digits = "".join(ch for ch in ln.split("bytes free")[0] if ch.isdigit())
            return int(digits) if digits else None
    return None

def measure_used_total(image_path: str) -> Dict[str, float]:
    """
    Measure via mdir only (robust): used = image_file_size - free_bytes_from_mdir.
    """
    free_bytes = _mdir_free_bytes(image_path)
    if free_bytes is None:
        raise RuntimeError("Could not read free bytes from mtools (mdir).")
    total_bytes = os.path.getsize(image_path)
    used_bytes  = max(0, total_bytes - free_bytes)
    used_mib  = used_bytes  / (1024.0 * 1024.0)
    total_mib = total_bytes / (1024.0 * 1024.0)
    return {
        "used_bytes": used_bytes,
        "total_bytes": total_bytes,
        "used_mib": used_mib,
        "total_mib": total_mib,
        "used_mib_1dp": _round_1dp_half_up(used_mib),
        "total_mib_1dp": _round_1dp_half_up(total_mib),
    }

# =================== Sanitize & Read-only ===================

def sanitize_image(image_path: str):
    """
    Remove macOS junk from the FAT image (without mounting).
    Safe to run multiple times; ignores missing paths.
    """
    def _silent(cmd):
        try: _run(cmd)
        except Exception: pass

    # Remove common macOS junk files
    for pat in ["::/.DS_Store", "::/*/.DS_Store", "::/._*", "::/*/._*"]:
        _silent(f'mdel -s -i "{image_path}" "{pat}"')

    # Attempt to remove known junk directories (must be empty)
    for _ in range(2):
        for d in [
            "::/.Spotlight-V100", "::/.fseventsd", "::/.Trashes",
            "::/.TemporaryItems", "::/.DocumentRevisions-V100",
            "::/System Volume Information"
        ]:
            _silent(f'mrd -i "{image_path}" "{d}"')

def make_readonly(image_path: str):
    """
    Make the image immutable/read-only at the filesystem level (macOS).
    Etcher can still read it; prevents accidental mounts from modifying it.
    """
    try:
        subprocess.run(["chmod", "444", image_path], check=False)
        subprocess.run(["chflags", "uchg", image_path], check=False)
    except Exception:
        # Non-macOS or missing chflags: ignore
        pass

# =================== Nudge (rough, single-shot) ===================

def _write_pad(image_path: str, dos_file: str, size_bytes: int):
    """
    Write pad file into the FAT image. Try bookInfo/.dup_sig; if that fails, fall back to root /.dup_sig.
    """
    def _write(dos_path: str):
        with tempfile.NamedTemporaryFile(prefix="pad_", delete=False) as tf:
            tmp = tf.name
        try:
            with open(tmp, "wb") as f:
                if size_bytes > 0:
                    f.truncate(size_bytes)
            _run(f'mcopy -o -i "{image_path}" "{tmp}" "{dos_path}"')
        finally:
            try: os.remove(tmp)
            except OSError: pass

    try:
        _write(dos_file)  # try ::/bookInfo/.dup_sig
    except Exception:
        _write("::/.dup_sig")  # fallback to root

def _nudge_single_shot(image_path: str, target_1dp: float, overall_timeout_s: float = 10.0) -> float:
    """
    One-shot center-of-band pad write, with tiny ± refinements.
    No ensure_dir; fast and robust.
    """
    t0 = time.time()
    MiB = 1024.0 * 1024.0
    def elapsed(): return f"{(time.time()-t0):.3f}s"

    print(f"[registry] nudge start → target {target_1dp:.1f}MiB", flush=True)

    pad = "::/bookInfo/.dup_sig"  # write_pad will fall back to root if needed

    # Measure current
    m0 = measure_used_total(image_path)
    current_1dp = _round_1dp_half_up(m0["used_mib"])
    if current_1dp == target_1dp:
        print(f"[registry] {elapsed()} already at target; no nudge", flush=True)
        return current_1dp

    # Target rounding band (half-up)
    lower  = (target_1dp - 0.05) * MiB
    upper  = (target_1dp + 0.049) * MiB  # exclusive-ish
    center =  target_1dp * MiB

    # Reset pad by writing zero bytes (overwrite)
    _write_pad(image_path, pad, 0)

    # Re-measure after reset
    m1 = measure_used_total(image_path)

    # If already >= upper band (no headroom to reduce), bail with current
    if m1["used_bytes"] >= upper:
        print(f"[registry] {elapsed()} used≥upper after reset; cannot reduce; stopping", flush=True)
        return _round_1dp_half_up(m1["used_mib"])

    # Single-shot to band center
    need = int(max(0, center - m1["used_bytes"]))
    print(f"[registry] {elapsed()} writing pad {need} bytes (center shot)…", flush=True)
    _write_pad(image_path, pad, need)

    # Re-measure
    m2 = measure_used_total(image_path)
    r2 = _round_1dp_half_up(m2["used_mib"])
    print(f"[registry] {elapsed()} after write → {r2:.1f}MiB", flush=True)
    if r2 == target_1dp:
        return r2

    # Tiny refine around center (±64 KiB, then ±16 KiB)
    for step in (64*1024, 16*1024):
        for adj in (+step, -step):
            if (time.time()-t0) > overall_timeout_s:
                print(f"[registry] {elapsed()} watchdog → stop refine", flush=True)
                return r2
            pad_bytes = max(0, need + adj)
            print(f"[registry] {elapsed()} refine {adj:+} bytes → pad {pad_bytes}", flush=True)
            _write_pad(image_path, pad, pad_bytes)
            m3 = measure_used_total(image_path)
            r3 = _round_1dp_half_up(m3["used_mib"])
            print(f"[registry] {elapsed()} refine result {r3:.1f}MiB", flush=True)
            if r3 == target_1dp:
                return r3

    return r2  # closest we reached

# =================== Slot selection ===================

def choose_free_slot(measured_1dp: float, max_cap_1dp: Optional[float] = None, span: int = 40) -> float:
    """
    Pick the first free 0.1 MiB slot at or ABOVE measured_1dp, optionally bounded by capacity.
    """
    occupied = get_occupied_slots_1dp()
    base = _round_1dp_half_up(measured_1dp)
    cap  = _round_1dp_half_up(max_cap_1dp) if max_cap_1dp is not None else None

    for i in range(0, span + 1):
        candidate = _round_1dp_half_up(base + 0.1 * i)
        if cap is not None and candidate > cap:
            break
        if f"{candidate:.1f}" not in occupied:
            return candidate
    return base  # nothing free within span/cap; don't move down

# =================== Optional guard ===================

def assert_matches_registry_or_fix(image_path: str, sku: str) -> None:
    """
    If SKU exists in the sheet, ensure the image still rounds to that slot after sanitize.
    If it mismatches, raise to stop downstream use.
    """
    _, recorded = find_sku_row(sku)
    if recorded is None:
        return
    sanitize_image(image_path)
    m = measure_used_total(image_path)
    current = m["used_mib_1dp"]
    if current != recorded:
        raise RuntimeError(
            f"Image used size {current:.1f}MiB != recorded {recorded:.1f}MiB for {sku}. "
            "Refuse to proceed—rebuild or re-watermark."
        )

# =================== Public API ===================

def claim_unique_slot_and_log(image_path: str, sku: str) -> Dict[str, str]:
    """
    1) Ensure header.
    2) Sanitize, then measure.
    3) If SKU exists and its recorded slot is reachable (>= measured and <= capacity),
       reuse it and DO NOT append (one row per SKU).
       Else pick next free slot at/above measured and (unless skip) nudge to it, then append.
    4) Finally, make the image read-only (immutable).
    """
    ensure_header()

    # Always sanitize first to remove OS junk if someone mounted the image
    sanitize_image(image_path)

    m0 = measure_used_total(image_path)
    measured_1dp = m0["used_mib_1dp"]
    total_1dp    = m0["total_mib_1dp"]

    # Check for existing SKU row
    row_idx, existing_slot = find_sku_row(sku)
    reuse = False
    target_1dp: float

    if existing_slot is not None:
        # Only reuse if we can reach it without downsizing and within capacity
        if existing_slot >= measured_1dp and existing_slot <= total_1dp:
            target_1dp = existing_slot
            reuse = True
            print(f"[registry] found existing SKU={sku} with slot {existing_slot:.1f}MiB → reusing; no append", flush=True)
        else:
            print(f"[registry] SKU={sku} has slot {existing_slot:.1f}MiB but it's not reachable (measured={measured_1dp:.1f}, cap={total_1dp:.1f}); choosing next free", flush=True)
            target_1dp = choose_free_slot(measured_1dp, max_cap_1dp=total_1dp)
    else:
        target_1dp = choose_free_slot(measured_1dp, max_cap_1dp=total_1dp)

    print(f"[registry] measured={measured_1dp:.1f}MiB (cap={total_1dp:.1f}) → target={target_1dp:.1f}MiB", flush=True)

    # Watermarking
    if SKIP_WATERMARK or measured_1dp == target_1dp:
        if SKIP_WATERMARK:
            print("[registry] BM_SKIP_WATERMARK=1 → skipping nudge", flush=True)
        m = m0
    else:
        start = time.time()
        landed = _nudge_single_shot(image_path, target_1dp, overall_timeout_s=10.0)
        print(f"[registry] landed at {landed:.1f}MiB; nudge took {time.time()-start:.2f}s; re-measuring…", flush=True)
        m = measure_used_total(image_path)

    # If reusing an existing SKU, ensure image still matches the registered slot after sanitize/nudge
    if reuse:
        assert_matches_registry_or_fix(image_path, sku)

    # Log row only if SKU not present already
    if not reuse:
        from time import gmtime, strftime
        row = {
            "timestamp_utc": strftime("%Y-%m-%d %H:%M:%S%z", gmtime()),
            "sku": sku,
            "image_path": image_path,

            "used_bytes": int(m["used_bytes"]),
            "used_mib": f'{m["used_mib"]:.6f}',
            "used_mib_1dp": f'{m["used_mib_1dp"]:.1f}',

            "total_bytes": int(m["total_bytes"]),
            "total_mib": f'{m["total_mib"]:.6f}',
            "total_mib_1dp": f'{m["total_mib_1dp"]:.1f}',

            "volume_label": sku[:11].upper(),
            "file_size_bytes": os.path.getsize(image_path),
        }
        print("[registry] appending row to sheet…", flush=True)
        append_row(row)
        print("[registry] append complete", flush=True)
        make_readonly(image_path)
        return row
    else:
        # Even on reuse, lock the image so it can't be dirtied by a mount
        make_readonly(image_path)
        return {
            "timestamp_utc": "",
            "sku": sku,
            "image_path": image_path,

            "used_bytes": int(m["used_bytes"]),
            "used_mib": f'{m["used_mib"]:.6f}',
            "used_mib_1dp": f'{m["used_mib_1dp"]:.1f}',

            "total_bytes": int(m["total_bytes"]),
            "total_mib": f'{m["total_mib"]:.6f}',
            "total_mib_1dp": f'{m["total_mib_1dp"]:.1f}',

            "volume_label": sku[:11].upper(),
            "file_size_bytes": os.path.getsize(image_path),
        }

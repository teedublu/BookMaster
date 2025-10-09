# models/usbdrive_writer.py
import subprocess
import threading
import os
import logging
import time
import tempfile

from utils.sudo_askpass import make_askpass_script

# Small internal exceptions for clearer control flow
class _UserCancelled(Exception):
    pass


class _StagingError(Exception):
    pass


# --- helpers ---
def _file_size_or_none(path: str):
    try:
        st = os.stat(path)
        return st.st_size if st.st_size > 0 else None
    except Exception:
        return None


def _looks_remote_path(p: str) -> bool:
    p = os.path.abspath(p)
    home = os.path.expanduser("~")
    roots = [
        os.path.join(home, "Library", "CloudStorage"),  # iCloud / Google Drive
        "/Volumes",  # SMB/AFP/NAS
    ]
    for root in roots:
        if os.path.exists(root):
            try:
                if os.path.commonpath([p, root]) == root:
                    return True
            except Exception:
                continue
    return False


def _cache_dir() -> str:
    # Keep cache on same APFS volume as home (and usually as CloudStorage) for fast CoW clone
    d = os.path.expanduser("~/Library/Caches/BookMaster")
    os.makedirs(d, exist_ok=True)
    return d


def _same_device(a: str, b: str) -> bool:
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except Exception:
        return False


def _is_fast_local(path: str, bytes_to_try: int = 2 * 1024 * 1024, timeout_s: float = 0.3) -> bool:
    # quick hydration probe; if this is slow, reading the whole file will be slow too
    start = time.monotonic()
    try:
        with open(path, "rb", buffering=0) as f:
            f.read(bytes_to_try)
    except Exception:
        return False
    return (time.monotonic() - start) <= timeout_s


def _try_fast_clone(src: str, dst: str) -> bool:
    """
    Attempt APFS clone (copy-on-write) using `cp -c`. Returns True on success.
    Only works if src and dst are on the same APFS volume and the provider exposes local bytes.
    """
    try:
        # ensure parent
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        # remove any stale file
        try:
            os.remove(dst)
        except FileNotFoundError:
            pass

        # must be same device for clonefile; otherwise this will copy, which we don't want
        if not _same_device(src, os.path.dirname(dst)):
            return False

        # if the file is quickly readable, cloning is likely to be instant
        if not _is_fast_local(src):
            return False

        # macOS cp -c triggers clonefile() (APFS CoW)
        res = subprocess.run(["/bin/cp", "-c", src, dst], capture_output=True)
        return res.returncode == 0 and os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src)
    except Exception:
        # any failure falls back to streaming
        try:
            if os.path.exists(dst):
                os.remove(dst)
        except Exception:
            pass
        return False


class ImageWriteTask:
    def __init__(self, parent_widget, image_path: str, raw_whole: str, log_cb=None, progress_cb=None, done_cb=None, use_sudo=True):
        self.parent = parent_widget
        self.image_path = image_path
        self.raw_whole = raw_whole
        self.use_sudo = use_sudo
        self.log_cb = log_cb or (lambda msg: None)
        self.progress_cb = progress_cb or (lambda pct: None)
        self.done_cb = done_cb or (lambda ok, err=None: None)
        self._stop = False
        self._thread = None
        self._pv = None
        self._dd = None
        self._pv_stage = None  # for staging pv

    def _stage_with_pv(self, src_path: str, start_pct: int = 0, end_pct: int = 30) -> str:
        """
        Stage src_path to a local temp file using `pv -n` while mapping percent to [start_pct..end_pct].
        Returns the staged local path on success.
        Raises _UserCancelled on cancel, _StagingError on I/O/pv failure.
        """
        total = _file_size_or_none(src_path)

        # Prepare destination
        dst_dir = os.path.join(tempfile.gettempdir(), "BookMaster")
        os.makedirs(dst_dir, exist_ok=True)
        dst_path = os.path.join(dst_dir, os.path.basename(src_path))

        # Reuse if already staged and sizes match
        if os.path.exists(dst_path) and (total is None or os.path.getsize(dst_path) == total):
            # snap progress to the end of staging range
            try:
                self.parent.after(0, self.progress_cb, end_pct)
            except Exception:
                pass
            return dst_path

        logging.debug(f"Staging cloud file locally {dst_path}")

        # Build pv command
        pv_cmd = ["pv", "-n"]
        if total is not None:
            pv_cmd += ["-s", str(total)]
        pv_cmd += [src_path]

        # Start pv -> file
        err_text = []
        with open(dst_path, "wb") as fout:
            self._pv_stage = subprocess.Popen(
                pv_cmd, stdout=fout, stderr=subprocess.PIPE, bufsize=0
            )

            # Read pv's numeric percent and map to start..end
            def read_pv_stage_stderr():
                buf = b""
                for ch in iter(lambda: self._pv_stage.stderr.read(1), b""):
                    if self._stop:
                        return
                    if ch in (b"\n", b"\r"):
                        s = buf.decode("utf-8", "ignore").strip()
                        if s:
                            # pv sometimes emits diagnostics if it can't stat size
                            if s.isdigit():
                                pct = max(0, min(100, int(s)))
                                mapped = start_pct + int((end_pct - start_pct) * (pct / 100.0))
                                try:
                                    self.parent.after(0, self.progress_cb, mapped)
                                except Exception:
                                    pass
                            else:
                                err_text.append(s)
                        buf = b""
                    else:
                        buf += ch

            t = threading.Thread(target=read_pv_stage_stderr, daemon=True)
            t.start()

            # Main wait loop with cancel support
            while True:
                rc = self._pv_stage.poll()
                if rc is not None:
                    break
                if self._stop:
                    try:
                        self._pv_stage.terminate()
                    except Exception:
                        pass
                    try:
                        self._pv_stage.wait(timeout=1)
                    except Exception:
                        pass
                    # Clean partial file
                    try:
                        fout.flush()
                        os.fsync(fout.fileno())
                    except Exception:
                        pass
                    try:
                        os.remove(dst_path)
                    except Exception:
                        pass
                    raise _UserCancelled("User cancelled during staging")
                time.sleep(0.05)

            t.join(timeout=0.2)

        logging.debug("pv exit")
        # pv exit handling
        if rc != 0:
            try:
                os.remove(dst_path)
            except Exception:
                pass
            msg = " ".join(err_text) or f"pv exited with code {rc}"
            raise _StagingError(msg)

        # If pv never reported percent (unknown size), still force end_pct
        try:
            self.parent.after(0, self.progress_cb, end_pct)
        except Exception:
            pass

        # Verify size if known
        if total is not None and os.path.getsize(dst_path) != total:
            try:
                os.remove(dst_path)
            except Exception:
                pass
            raise _StagingError(f"Short copy: expected {total} bytes, got {os.path.getsize(dst_path)}")

        logging.debug(f"Staging finished {dst_path}")
        return dst_path

    def _stage_to_local(self, src_path: str, status_label="Loading image…") -> str:
        """
        Legacy: Stream-copy src_path to a local temp file while updating progress_cb.
        (Kept for reference; pv-based staging is preferred.)
        """
        self.parent.after(0, self.progress_cb, 0)  # show we started
        size = os.path.getsize(src_path)
        # Keep the same filename so later logs are clearer
        dst_dir = os.path.join(tempfile.gettempdir(), "BookMaster")
        os.makedirs(dst_dir, exist_ok=True)
        dst_path = os.path.join(dst_dir, os.path.basename(src_path))

        # If already staged and size matches, reuse
        if os.path.exists(dst_path) and os.path.getsize(dst_path) == size:
            return dst_path

        # Stream read/write in chunks so Tk can breathe
        bytes_done = 0
        chunk = 8 * 1024 * 1024  # 8MB
        with open(src_path, "rb") as fin, open(dst_path, "wb") as fout:
            while True:
                if self._stop:
                    raise RuntimeError("Cancelled")
                buf = fin.read(chunk)
                if not buf:
                    break
                fout.write(buf)
                bytes_done += len(buf)
                # Map to 0–30%
                pct = int(30 * (bytes_done / size))
                self.parent.after(0, self.progress_cb, pct)
                # Let Tk update
                time.sleep(0.005)

        # Ensure fully flushed
        try:
            os.fsync(fout.fileno())
        except Exception:
            pass
        return dst_path

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def cancel(self):
        self._stop = True
        # terminate staging pv if running
        try:
            if self._pv_stage and self._pv_stage.poll() is None:
                self._pv_stage.terminate()
        except Exception:
            pass
        for p in (self._pv, self._dd):
            try:
                if p and p.poll() is None:
                    p.terminate()
            except Exception:
                pass

    def _run(self):
        try:
            # --- Unmount + exclusive access ---
            disk_node = self.raw_whole.replace("/dev/r", "/dev/")
            from .usbdrive import USBDrive  # adjust import if needed
            USBDrive._safe_unmount_whole(disk_node)
            USBDrive._ensure_exclusive_access(disk_node)

            # --- Decide source (clone if possible; else stream direct with hydration pulse) ---
            image_src = self.image_path
            staged = False

            if _looks_remote_path(image_src):
                cache_path = os.path.join(_cache_dir(), os.path.basename(image_src))

                # 1) Try APFS fast clone (instant if file truly local)
                if _try_fast_clone(image_src, cache_path):
                    image_src = cache_path
                    staged = True
                    try:
                        self.parent.after(0, self.progress_cb, 30)  # jump staging range instantly
                    except Exception:
                        pass

                # 2) Else if clearly not local/fast, stage with pv (show progress)
                elif not _is_fast_local(image_src):
                    try:
                        image_src = self._stage_with_pv(image_src, start_pct=0, end_pct=30)
                        staged = True
                    except _UserCancelled:
                        self.parent.after(0, self.done_cb, False, "Cancelled")
                        return
                    except _StagingError as e:
                        self.parent.after(0, self.done_cb, False, f"Staging error: {e}")
                        return

            # --- Write stage (pv -> dd), mapping 30–100% if staged ---
            total_write = _file_size_or_none(image_src)
            pv_cmd = ["pv", "-n"]
            if total_write is not None:
                pv_cmd += ["-s", str(total_write)]
            pv_cmd += [image_src]

            env = os.environ.copy()
            dd_cmd = ["dd", f"of={self.raw_whole}", "bs=4m", "conv=fsync"]
            if self.use_sudo:
                env["SUDO_ASKPASS"] = make_askpass_script()
                dd_cmd = ["sudo", "-A"] + dd_cmd

            self._pv = subprocess.Popen(
                pv_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0
            )
            self._dd = subprocess.Popen(
                dd_cmd,
                stdin=self._pv.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                bufsize=0,
            )
            self._pv.stdout.close()

            # --- progress readers ---
            first_percent_seen = {"v": False}

            def read_pv_stderr():
                b = b""
                for ch in iter(lambda: self._pv.stderr.read(1), b""):
                    if self._stop:
                        return
                    if ch in (b"\n", b"\r"):
                        s = b.decode("utf-8", "ignore").strip()
                        b = b""
                        if s.isdigit():
                            first_percent_seen["v"] = True
                            write_pct = max(0, min(100, int(s)))
                            overall = (30 + int(write_pct * 0.70)) if staged else write_pct
                            try:
                                self.parent.after(0, self.progress_cb, overall)
                            except Exception:
                                pass
                    else:
                        b += ch

            # "hydrating" pulse while pv hasn't emitted any percent yet (direct-from-Drive case)
            def hydration_pulse():
                if self._stop or first_percent_seen["v"]:
                    return
                # simple 1..5..1 pulse
                hydration_pulse.state = (hydration_pulse.state % 5) + 1
                try:
                    self.parent.after(0, self.progress_cb, hydration_pulse.state)
                except Exception:
                    pass
                # reschedule if still waiting
                if not first_percent_seen["v"]:
                    self.parent.after(250, hydration_pulse)

            hydration_pulse.state = 0

            # Start threads + pulse
            t = threading.Thread(target=read_pv_stderr, daemon=True)
            t.start()
            # Only start pulse if not staged (direct cloud stream)
            if not staged:
                hydration_pulse()

            # Wait for completion
            dd_out, dd_err = self._dd.communicate()
            self._pv.wait()
            t.join(timeout=0.2)

            if self._stop:
                self.parent.after(0, self.done_cb, False, "Cancelled")
                return
            if self._dd.returncode != 0:
                err = (dd_err or b"").decode("utf-8", "ignore")
                self.parent.after(0, self.done_cb, False, f"dd failed: {err}")
                return

            self.parent.after(0, self.progress_cb, 100)
            self.parent.after(0, self.done_cb, True, None)

        except subprocess.CalledProcessError as e:
            self.parent.after(0, self.done_cb, False, f"Command failed: {e}")
        except Exception as e:
            self.parent.after(0, self.done_cb, False, str(e))

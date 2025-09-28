# models/usbdrive_writer.py
import subprocess, threading, queue, os, re, logging, time
from utils.sudo_askpass import make_askpass_script

class ImageWriteTask:
    def __init__(self, parent_widget, image_path:str, raw_whole:str, log_cb=None, progress_cb=None, done_cb=None, use_sudo=True):
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

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def cancel(self):
        self._stop = True
        for p in (self._pv, self._dd):
            try:
                if p and p.poll() is None:
                    p.terminate()
            except Exception:
                pass

    def _run(self):
        try:
            # Unmount the whole device first
            subprocess.run(["/usr/sbin/diskutil", "unmountDisk", self.raw_whole.replace("/dev/r","/dev/")], check=True)

            # pv prints numeric percentage to STDERR with -n
            pv_cmd = ["pv", "-n", self.image_path]

            # dd needs sudo on macOS; use askpass GUI (no terminal needed)
            env = os.environ.copy()
            dd_cmd = ["dd", f"of={self.raw_whole}", "bs=4m", "conv=fsync"]
            if self.use_sudo:
                env["SUDO_ASKPASS"] = make_askpass_script()
                dd_cmd = ["sudo", "-A"] + dd_cmd

            self._pv = subprocess.Popen(
                pv_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0
            )
            self._dd = subprocess.Popen(
                dd_cmd,
                stdin=self._pv.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                bufsize=0
            )
            self._pv.stdout.close()  # allow SIGPIPE if dd exits early

            # Read pv numeric progress on a side thread
            def read_pv_stderr():
                percent_buf = b""
                for chunk in iter(lambda: self._pv.stderr.read(1), b""):
                    if self._stop: return
                    if chunk in (b"\n", b"\r"):
                        s = percent_buf.decode("utf-8", "ignore").strip()
                        percent_buf = b""
                        if s.isdigit():
                            pct = min(100, max(0, int(s)))
                            self.parent.after(0, self.progress_cb, pct)
                    else:
                        percent_buf += chunk

            t = threading.Thread(target=read_pv_stderr, daemon=True)
            t.start()

            # Wait for dd to finish
            dd_out, dd_err = self._dd.communicate()
            self._pv.wait()  # ensure pv ends too
            t.join(timeout=0.2)

            if self._stop:
                self.parent.after(0, self.done_cb, False, "Cancelled")
                return

            if self._dd.returncode != 0:
                err = (dd_err or b"").decode("utf-8", "ignore")
                self.parent.after(0, self.done_cb, False, f"dd failed: {err}")
                return

            # success
            self.parent.after(0, self.progress_cb, 100)
            self.parent.after(0, self.done_cb, True, None)

        except subprocess.CalledProcessError as e:
            self.parent.after(0, self.done_cb, False, f"Command failed: {e}")
        except Exception as e:
            self.parent.after(0, self.done_cb, False, str(e))

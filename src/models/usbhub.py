import psutil
import os
import time
import threading
import subprocess
import platform
import hashlib
import logging
import traceback
from typing import Dict, List, Callable, Optional
from models import USBDrive

class USBHub:
    def __init__(self, callback: Optional[Callable[[dict], None]] = None,
                 mountpoint: str = "/Volumes",
                 poll_interval: float = 2.0):
        """
        Monitor and manage connected USB drives.

        Args:
            callback: Called with {"added": {mp: USBDrive}, "removed": {mp: USBDrive}, "snapshot": {mp: USBDrive}}
                      whenever a change is detected.
            mountpoint: Base directory where USB drives are mounted (macOS '/Volumes'; Linux '/media' or '/mnt').
            poll_interval: Seconds between polls.
        """
        self.mountpoint = mountpoint
        self.poll_interval = poll_interval

        self.drives: Dict[str, USBDrive] = {}
        self.drive_list: List[str] = []
        self.callback = callback if callable(callback) else None

        self.lock = threading.Lock()
        self._stop = threading.Event()

        self.monitor_thread = threading.Thread(target=self._monitor_loop, name="USBHubMonitor", daemon=True)
        self.monitor_thread.start()

        self.ui_context = None

    # ----- lifecycle ---------------------------------------------------------

    def stop(self, timeout: Optional[float] = 5.0):
        """Stop the background monitoring thread."""
        self._stop.set()
        self.monitor_thread.join(timeout=timeout)

    # ----- properties --------------------------------------------------------

    @property
    def has_available_drive(self) -> bool:
        """Check if at least one USB drive is connected."""
        with self.lock:
            return bool(self.drives)

    @property
    def first_available_drive(self) -> Optional[USBDrive]:
        """Return the first available USBDrive object, or None if no drive is found."""
        with self.lock:
            return next(iter(self.drives.values()), None)

    # ----- monitoring --------------------------------------------------------

    def _monitor_loop(self):
        try:
            while not self._stop.is_set():
                try:
                    self._poll_once()
                except Exception:
                    logging.exception("USBHub: unhandled error during poll")
                finally:
                    # Sleep even on exception; allow early exit if stop is set
                    self._stop.wait(self.poll_interval)
        finally:
            logging.debug("USBHub: monitor stopped")

    def _poll_once(self):
        current_drives = self.get_usb_drives()  # {mountpoint: USBDrive}

        with self.lock:
            prev = self.drives
            added = {mp: drv for mp, drv in current_drives.items() if mp not in prev}
            removed = {mp: drv for mp, drv in prev.items() if mp not in current_drives}

            if not added and not removed:
                # logging.debug("USBHub: no changes detected; polling…")
                return

            # Apply updates
            for mp, drv in added.items():
                logging.info("🔌 New drive: %s (%s)", mp, getattr(drv, "device_path", ""))
                self.drives[mp] = drv

            for mp in list(removed.keys()):
                logging.info("[USBHUB] Drive removed: %s", mp)
                self.drives.pop(mp, None)

            # Refresh presentation list
            self.drive_list = list(self.drives.keys())
            snapshot = dict(self.drives)

        # Fire callback OUTSIDE the lock
        if self.callback:
            try:
                self.callback({
                    "added": added,
                    "removed": removed,
                    "snapshot": snapshot,
                })
            except Exception:
                logging.exception("USBHub: callback raised an exception")

    # ----- discovery ---------------------------------------------------------

    def get_usb_drives(self) -> Dict[str, USBDrive]:
        """
        Detect connected USB drives and return them as a dictionary.
        Returns:
            dict: {mountpoint: USBDrive} of available drives.
        """
        drives: Dict[str, USBDrive] = {}

        try:
            for part in psutil.disk_partitions(all=False):
                # restrict to expected mount base and FAT-like filesystems we care about
                if not part.mountpoint.startswith(self.mountpoint):
                    continue
                if part.fstype.lower() not in ("exfat", "vfat", "msdos", "fat", "fat32"):
                    continue

                device_path = self.get_device_path(part.mountpoint)
                if not device_path:
                    logging.debug(f"USBHub: get_device_path is None")
                    continue

                # Reuse existing instance where possible
                if part.mountpoint in self.drives:
                    drives[part.mountpoint] = self.drives[part.mountpoint]
                else:
                    logging.debug(f"USBHub: creating USBDrive for {part.mountpoint} @ {device_path}")
                    drv = USBDrive(part.mountpoint, device_path, self.ui_context)
                    drives[part.mountpoint] = drv

        except Exception as e:
            tb = traceback.extract_tb(e.__traceback__)[-1]
            logging.debug(f"USBHub: error getting USB drives at {tb.filename}:{tb.lineno}: {e}")

        return drives

    def get_snapshot(self) -> List[USBDrive]:
        """Return a copy of the current drive objects."""
        with self.lock:
            return list(self.drives.values())

    # ----- helpers -----------------------------------------------------------

    def get_device_path(self, mountpoint: str) -> Optional[str]:
        """
        Find the raw device path corresponding to a given mountpoint (macOS).
        Returns '/dev/rdiskX' when available for faster raw I/O; falls back to '/dev/diskX'.
        """
        if platform.system() != "Darwin":
            # On Linux you could resolve from /proc/mounts or lsblk; keep your previous approach if needed.
            return None

        try:
            result = subprocess.run(
                ["diskutil", "info", mountpoint],
                capture_output=True, text=True, check=True
            )
            dev_node = None
            for line in result.stdout.splitlines():
                if "Device Node:" in line:
                    dev_node = line.split(":", 1)[-1].strip()
                    break
            if not dev_node:
                return None

            # Prefer raw device if present (rdiskX)
            raw = dev_node.replace("/dev/disk", "/dev/rdisk")
            if os.path.exists(raw):
                return raw
            return dev_node
        except subprocess.CalledProcessError as e:
            logging.error(f"USBHub: failed to retrieve device path for {mountpoint}: {e}")
            return None

    def update_drive_list(self):
        """Kept for backward-compat; prefer callback payload from _poll_once."""
        with self.lock:
            self.drive_list = list(self.drives.keys())
            payload = {"added": {}, "removed": {}, "snapshot": dict(self.drives)}
        if self.callback:
            try:
                self.callback(payload)
            except Exception:
                logging.exception("USBHub: callback raised in update_drive_list")

    def get_drive_list(self) -> List[str]:
        """Expose the list of connected drive mountpoints."""
        with self.lock:
            return list(self.drive_list)

    # ----- device ops (static) ----------------------------------------------

    @staticmethod
    def eject_disk(disk_identifier: str) -> bool:
        """
        Ejects a disk on macOS using diskutil.
        :param disk_identifier: The identifier of the disk (e.g., 'disk2' or 'disk3s1').
        """
        try:
            result = subprocess.run(
                ["diskutil", "eject", disk_identifier],
                capture_output=True, text=True, check=True
            )
            logging.info(result.stdout.strip())
            return True
        except subprocess.CalledProcessError as e:
            logging.error(f"Error ejecting {disk_identifier}: {e.stderr.strip()}")
            return False

    @staticmethod
    def erase_removable_drive(device_path: str, filesystem: str = "exfat", label: str = "USB_DRIVE") -> bool:
        """
        Erases a removable drive and formats it with the specified filesystem.
        On macOS, uses diskutil; on Linux, uses mkfs.* tools.
        """
        system_os = platform.system()

        try:
            # 1) Unmount whole device
            logging.info(f"Unmounting {device_path}...")
            if system_os == "Darwin":
                subprocess.run(["diskutil", "unmountDisk", device_path], check=True)
            elif system_os == "Linux":
                subprocess.run(["umount", device_path], check=True)

            # 2) Format
            logging.info(f"Formatting {device_path} as {filesystem}...")
            if system_os == "Darwin":
                # NOTE: For super-floppy (no partition table), prefer newfs_msdos directly:
                #   sudo newfs_msdos -F 32 -v <LABEL> /dev/rdiskX
                if filesystem.lower() in ("msdos", "fat", "fat32", "vfat"):
                    raw = device_path.replace("/dev/disk", "/dev/rdisk")
                    subprocess.run(["newfs_msdos", "-F", "32", "-v", label, raw], check=True)
                else:
                    subprocess.run(["diskutil", "eraseDisk", filesystem, label, device_path], check=True)

            elif system_os == "Linux":
                fs = filesystem.lower()
                if fs == "exfat":
                    subprocess.run(["mkfs.exfat", "-n", label, device_path], check=True)
                elif fs in ("vfat", "fat", "fat32", "msdos"):
                    subprocess.run(["mkfs.vfat", "-n", label, device_path], check=True)
                elif fs == "ext4":
                    subprocess.run(["mkfs.ext4", "-L", label, device_path], check=True)
                else:
                    logging.error(f"Unsupported filesystem: {filesystem}")
                    return False

            logging.info(f"Drive {device_path} erased and formatted as {filesystem} successfully.")
            return True

        except subprocess.CalledProcessError as e:
            logging.error(f"Error erasing drive {device_path}: {e}")
            return False


if __name__ == "__main__":
    hub = USBHub()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        hub.stop()

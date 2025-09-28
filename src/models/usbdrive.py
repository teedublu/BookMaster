import psutil
import os, sys, plistlib
import re
import logging
import time
import threading
import subprocess
import pathlib
import hashlib, shlex, json
from dataclasses import dataclass
from typing import Optional, Tuple
from natsort import natsorted
from utils import compute_sha256
from pathlib import Path
from utils import MasterValidator
from models import MasterDraft  # Import Master class
from .usbdrive_writer import ImageWriteTask


# _SLICE_RE = re.compile(r"^/dev/r?disk(\d+)(s\d+)?$")
DD_SUMMARY_RE = re.compile(r"(?P<bytes>\d+)\s+bytes transferred in\s+(?P<secs>[0-9.]+)\s+secs\s+\((?P<bps>\d+)\s+bytes/sec\)")

# Compile once at module scope
_SLICE_RE = re.compile(r"^/dev/(?:r)?disk(\d+)(?:s\d+)?$")

@dataclass(frozen=True)
class DriveInfo:
    # Core
    mountpoint: str
    device_node: Optional[str]          # e.g. /dev/disk5s1 (slice)
    raw_whole: Optional[str]            # e.g. /dev/rdisk5 (whole raw disk)

    # Capacity / usage
    usage: Optional[psutil._common.sdiskusage]
    capacity_gb: Optional[float]
    used_gb: Optional[float]
    free_gb: Optional[float]

    # File system
    fs_type: Optional[str]              # e.g. "apfs", "exfat"
    fs_label: Optional[str]             # Volume name
    fs_uuid: Optional[str]              # Volume/Media UUID

    # Heuristics
    is_single_volume: Optional[bool]
    is_valid_master: Optional[dict]

    # USB metadata (macOS via system_profiler)
    usb_serial: Optional[str]           # ← requested
    usb_vendor: Optional[str]
    usb_product: Optional[str]
    usb_manufacturer: Optional[str]
    usb_location_id: Optional[str]      # e.g. "0x14100000"


class USBDrive:
    def __init__(self, mountpoint, device_path=None, ui_context=None):
        """
        Initialize USBDrive with its mountpoint.
        """
        self.mountpath = Path(mountpoint) #eg /Volumes/AA11111AA
        self.mountpoint = mountpoint.rstrip("/")
        self._info: Optional[DriveInfo] = None  # cache

        self.device_path = device_path or self.get_device_path()  # eg "/dev/disk4"
        # self.capacity = self.get_capacity()
        # self.properties = self.drive_properties() # contains capacity, device_path etc so could use from here
        self.ui_context = ui_context
        self.speed = None  # To be determined via test
        self.current_content = {}
        self.content = None
        self.is_master = self.is_master()
        self.checksum = None
        self.stored_checksum = None
        self.is_checksum_valid = None
        # self.ui_context = ui_context
        logging.debug(f"USBDrive found mountpoint at {self.mountpoint}")
        
        # if self.is_master :
        #     self.checksum = self.compute_checksum()  # Compute actual checksum
        #     self.stored_checksum = self.load_stored_checksum()  # Load stored checksum
        #     self.is_checksum_valid = self.checksum_matches()  # Check if they match
        #     logging.debug(f"Inserted drive is likely Master checksum:{self.is_checksum_valid}")

    @staticmethod
    def _normalize_to_raw_whole(devnode: str) -> Optional[str]:
        """
        Accepts /dev/disk4, /dev/rdisk4, /dev/disk4s1, /dev/rdisk4s1
        Returns /dev/rdisk4 or None if unrecognized.
        """
        m = _SLICE_RE.match(devnode)
        if not m:
            return None
        return f"/dev/rdisk{m.group(1)}"

    @staticmethod
    def _normalize_to_nodes(devnode: str) -> Tuple[str, str]:
        """
        Returns (diskutil_node, raw_whole) -> (/dev/diskX, /dev/rdiskX)
        Raises on unrecognized.
        """
        m = _SLICE_RE.match(devnode)
        if not m:
            raise RuntimeError(f"Unrecognized device node: {devnode}")
        num = m.group(1)
        return f"/dev/disk{num}", f"/dev/rdisk{num}"

    @staticmethod
    def _diskutil_info_plist(target: str) -> Optional[dict]:
        try:
            res = subprocess.run(
                ["diskutil", "info", "-plist", target],
                capture_output=True, text=False, check=True
            )
            return plistlib.loads(res.stdout)
        except subprocess.CalledProcessError as e:
            logging.error("diskutil info -plist failed for %s: %s", target, e)
            return None

    @staticmethod
    def _system_profiler_usb_json() -> Optional[list]:
        try:
            res = subprocess.run(
                ["system_profiler", "SPUSBDataType", "-json"],
                capture_output=True, text=True, check=True
            )
            data = json.loads(res.stdout)
            return data.get("SPUSBDataType", [])
        except subprocess.CalledProcessError as e:
            logging.debug("system_profiler SPUSBDataType failed: %s", e)
            return None

    @staticmethod
    def _flatten_usb_tree(items: list) -> list:
        flat = []
        stack = list(items or [])
        while stack:
            node = stack.pop()
            flat.append(node)
            kids = node.get("_items")
            if isinstance(kids, list):
                stack.extend(kids)
        return flat

    @staticmethod
    def _usb_node_by_bsd_name(want_bsd: str) -> dict | None:
        try:
            res = subprocess.run(
                ["system_profiler", "SPUSBDataType", "-json"],
                capture_output=True, text=True, check=True
            )
            roots = json.loads(res.stdout).get("SPUSBDataType", [])
        except subprocess.CalledProcessError as e:
            logging.debug("system_profiler failed: %s", e)
            return None

        def walk(n):
            yield n
            for c in n.get("_items", []) or []:
                yield from walk(c)

        for r in roots:
            for n in walk(r):
                # 1) direct match on node
                b = n.get("bsd_name")
                if isinstance(b, str) and (b == want_bsd or b.startswith(want_bsd + "s")):
                    return n
                # 2) match inside Media list
                for m in n.get("Media", []) or []:
                    b = m.get("bsd_name")
                    if isinstance(b, str) and (b == want_bsd or b.startswith(want_bsd + "s")):
                        return n
        return None

    def _usb_match_by_location(self, io_registry_path: Optional[str]) -> dict | None:
        """Match USB node by Location ID parsed from diskutil IORegistry path."""
        if not io_registry_path:
            return None
        m = re.search(r"@([0-9A-Fa-f]+)\b", io_registry_path)
        if not m:
            return None
        want_loc = "0x" + m.group(1).lower()

        tree = self._system_profiler_usb_json()
        if not tree:
            return None

        for node in self._flatten_usb_tree(tree):
            loc = str(node.get("location_id", "")).lower()
            if loc == want_loc:
                return node
        return None

    def _usb_node_by_locid(locid_want: str | None) -> dict | None:
        if not locid_want:
            return None
        import json, subprocess
        res = subprocess.run(
            ["system_profiler", "SPUSBDataType", "-json"],
            capture_output=True, text=True, check=True
        )
        roots = json.loads(res.stdout).get("SPUSBDataType", [])

        def walk(n):
            yield n
            for c in n.get("_items", []) or []:
                yield from walk(c)

        locid_want = _normalize_locid(locid_want)
        for r in roots:
            for n in walk(r):
                loc = _normalize_locid(n.get("location_id"))
                if loc and loc == locid_want:
                    return n
        return None

    # ---------- Properties ----------
    @property
    def info(self) -> DriveInfo:
        """Cached DriveInfo; call refresh_info() to update."""
        if self._info is None:
            return self.refresh_info()
        return self._info

    @property
    def capacity_gb(self) -> Optional[float]:
        """Total capacity in GiB (binary GB)."""
        u = self.info.usage
        return round(u.total / (1024 ** 3), 2) if u else None

    def refresh_info(self) -> DriveInfo:
        mp = self.mountpoint
        logging.debug("Refreshing DriveInfo for %s", mp)

        self.content = MasterValidator(self)
        fix = self.ui_context.settings.get("usb_drive_check_on_mount", False)
        is_valid_master = self.content.validate(fix_system_files=fix)


        # diskutil (plist) once; use mountpoint so it resolves the slice
        di = self._diskutil_info_plist(mp) or {}

        device_node = di.get("DeviceNode")
        bsd = device_node.split("/")[-1] if device_node else None

        raw_whole = self._normalize_to_raw_whole(device_node) if device_node else None
        if raw_whole and not os.path.exists(raw_whole):
            raw_whole = None

        # Usage
        try:
            usage = psutil.disk_usage(mp)
        except Exception as e:
            logging.warning("psutil.disk_usage failed for %s: %s", mp, e)
            usage = None

        capacity_gb = round(usage.total / (1024**3), 2) if usage else None
        used_gb     = round(usage.used  / (1024**3), 2) if usage else None
        free_gb     = round(usage.free  / (1024**3), 2) if usage else None

        # FS details (prefer plist keys)
        fs_type  = (di.get("FileSystemPersonality") or di.get("FilesystemName") or None)
        fs_label = (di.get("VolumeName") or di.get("MediaName") or None)
        fs_uuid  = (di.get("VolumeUUID") or di.get("MediaUUID") or None)

        # Single-volume heuristic: count partitions on the same base disk
        is_single_volume: Optional[bool] = None
        if device_node:
            try:
                parts = psutil.disk_partitions(all=True)
                base_disk, _ = self._normalize_to_nodes(device_node)
                related = [p for p in parts if p.device.startswith(base_disk)]
                is_single_volume = (len(related) == 1)
            except Exception as e:
                logging.debug("single-volume check failed: %s", e)

        # USB metadata (match by IORegistry path -> Location ID -> system_profiler)
        io_path = di.get("IORegistryEntryPath") or di.get("IODeviceTreePath")

        usb_node = self._usb_node_by_bsd_name(bsd) if bsd else None
        # usb_node = self._usb_match_by_location(io_path)
        if not usb_node:
            usb_node = _usb_node_by_locid(di.get("DeviceTreePath") or di.get("IORegistryEntryPath"))

        def norm(d, *keys):
            """Pick first present key from d and return a trimmed string or None."""
            if not d:
                return None
            v = next((d.get(k) for k in keys if d.get(k) not in (None, "")), None)
            if v is None:
                return None
            v = str(v).replace("\u00A0", " ")           # NBSP → space
            v = " ".join(v.split())                     # trims & collapses whitespace
            return v or None

        usb_serial       = (usb_node.get("serial_num") if usb_node else None)
        usb_vendor       = norm(usb_node, "vendor_id", "vendor")
        usb_product      = norm(usb_node, "product_id", "_name")
        usb_manufacturer = norm(usb_node, "manufacturer")
        usb_location_id  = (usb_node.get("location_id") if usb_node else None)

        info = DriveInfo(
            mountpoint=mp,
            device_node=device_node,
            raw_whole=raw_whole,
            usage=usage,
            capacity_gb=capacity_gb,
            used_gb=used_gb,
            free_gb=free_gb,
            fs_type=(fs_type.lower() if isinstance(fs_type, str) else fs_type),
            fs_label=fs_label,
            fs_uuid=fs_uuid,
            is_single_volume=is_single_volume,
            is_valid_master=is_valid_master,
            usb_serial=usb_serial,
            usb_vendor=usb_vendor,
            usb_product=usb_product,
            usb_manufacturer=usb_manufacturer,
            usb_location_id=usb_location_id,
        )
        self._info = info
        return info


    def compute_checksum(self):
        """Computes a SHA-256 checksum for all files in the USB drive, excluding system files and /bookInfo/checksum.txt."""
        
        EXCLUDED_FILES = {"checksum.txt", ".DS_Store", "Thumbs.db"}
        EXCLUDED_DIRS = {".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"}

        # Get all valid files recursively, excluding system files and directories
        file_paths = natsorted(
            [
                file for file in self.mountpoint.rglob("*") 
                if file.is_file() 
                and file.name not in EXCLUDED_FILES  # Exclude specific files
                and not any(excluded in file.parts for excluded in EXCLUDED_DIRS)  # Exclude hidden/system directories
            ]
        )
        
        try:
            checksum_value = compute_sha256(file_paths)
            logging.info(f"Computed drive checksum: {checksum_value}")
            return checksum_value
        except Exception as e:
            logging.error(f"Failed to compute checksum: {e}")
            return None

    def load_stored_checksum(self):
        """Loads the expected checksum from /bookinfo/checksum.txt if available."""
        checksum_path = self.mountpoint / "bookInfo" / "checksum.txt"

        if not checksum_path.is_file():
            logging.warning("No checksum.txt found in bookinfo directory.")
            return None

        try:
            with checksum_path.open("r", encoding="utf-8") as f:
                return f.read().strip()
        except Exception as e:
            logging.error(f"Failed to read 'checksum.txt': {e}")
            return None

    def checksum_matches(self):
        """Checks if computed checksum matches the stored checksum."""
        return self.checksum and self.stored_checksum and self.checksum == self.stored_checksum


    def write_disk_image_async(self, image_path, ui_parent, on_progress, on_done, use_sudo=True):
        image_path = Path(image_path)
        if not image_path.is_file() or image_path.suffix.lower() != ".img":
            raise ValueError("Invalid .img path")

        # Normalize to whole/raw nodes as you already do
        diskutil_node, raw_whole = self._normalize_to_nodes(self.device_path)

        task = ImageWriteTask(
            parent_widget=ui_parent,
            image_path=str(image_path),
            raw_whole=raw_whole,
            use_sudo=use_sudo,
            progress_cb=on_progress,
            done_cb=on_done,
            log_cb=lambda m: logging.info(m),
        )
        task.start()
        return task  # keep a reference to allow cancel

    def write_disk_image(self, image_path, use_sudo=False):
        """
        Writes the provided disk image to the USB drive using 'dd'.

        Args:
            image_path (str): Path to the disk image file (.img).
            use_sudo (bool): Whether to use 'sudo' (default: True).

        Raises:
            ValueError: If the image file is invalid.
            RuntimeError: If an error occurs during writing.
        """
        # Validate image file

        image_path = Path(image_path)

        # Validate
        if not image_path.is_file():
            raise ValueError(f"The image file does not exist: {image_path}")
        if image_path.suffix.lower() != ".img":
            raise ValueError("The provided image path does not have a .img extension.")

        if not self.device_path:
            raise RuntimeError("Could not determine the raw device path.")

        image_str = str(image_path)

        self.write_image_with_progress(image_str, self.device_path, use_sudo=use_sudo)



    def write_image_with_progress(self, image_str: str, devnode: str, use_sudo: bool = False):
        # Resolve to whole-disk nodes
        diskutil_node, raw_whole = self._normalize_to_nodes(devnode)

        # Unmount the *whole* device
        logging.info(f"Unmounting whole device {diskutil_node} …")
        subprocess.run(["diskutil", "unmountDisk", diskutil_node], check=True)

        cmd = f"pv {image_str} | sudo dd of={raw_whole} bs=4m conv=fsync"
        
        pv = subprocess.Popen(
            ["pv", image_str],
            stdout=subprocess.PIPE,
            stderr=sys.stderr
        )

        # Pipe into dd
        dd = subprocess.Popen(
            ["sudo", "dd", f"of={raw_whole}", "bs=4m", "conv=fsync"],
            stdin=pv.stdout,
            stderr=sys.stderr
        )

        pv.stdout.close()  # allow SIGPIPE if dd exits early
        dd_stdout, dd_stderr = dd.communicate()
        dd.wait()
        pv.wait()

        

        if dd_stderr:
            logging.debug(f"dd process output (stderr):\n{dd_stderr.decode('utf-8')}")


    def is_empty(self):
        """Check if drive is empty, ignoring system files."""
        SYSTEM_FILES = {".Spotlight-V100", ".fseventsd", "System Volume Information", ".Trash"}
        try:
            files = [f for f in os.listdir(self.mountpoint) if f not in SYSTEM_FILES]
            return len(files) == 0
        except Exception as e:
            print(f"Error checking if drive {self.mountpoint} is empty: {e}")
            return False

    def test_speed(self):
        """Run a basic read/write speed test on the drive."""
        test_file = os.path.join(self.mountpoint, "speed_test.tmp")
        try:
            # Write test
            start_time = time.time()
            with open(test_file, "wb") as f:
                f.write(b"0" * 1024 * 1024 * 100)  # 100MB test file
            write_time = time.time() - start_time

            # Read test
            start_time = time.time()
            with open(test_file, "rb") as f:
                f.read()
            read_time = time.time() - start_time

            # Cleanup
            os.remove(test_file)

            self.speed = {"write": 100 / write_time, "read": 100 / read_time}  # MB/s
            print(f"Speed Test Results for {self.mountpoint}: {self.speed}")
        except Exception as e:
            print(f"Error testing drive speed: {e}")

    def load_existing(self):
         
        if not self.ui_context:
            logging.warning(f"No UI context ready. Stopping.")
            return

        if not self.is_master:
            logging.warning(f"Trying to check an invalid Master. Stopping.")
            return

        try:
            # Construct file paths
            isbn_path = Path(self.mountpoint) / "bookInfo" / "id.txt"
            file_count_path = Path(self.mountpoint) / "bookInfo" / "count.txt"
            tracks_path = Path(self.mountpoint) / "tracks"
            metadata_file = Path(self.mountpoint) / '.metadata_never_index'

            # Read ISBN
            if isbn_path.exists():
                self.current_content["isbn"] = isbn_path.read_text(encoding="utf-8").strip()
            
            # Read file count
            if file_count_path.exists():
                self.current_content["file_count"] = file_count_path.read_text(encoding="utf-8").strip()
            
            # count files
            # self.current_content["files_found"] = check_input(tracks_path)

            # self.current_content["tracks_check"] = check_mp3_folder(tracks_path)

            # metafile present
            self.current_content["metadata_file"] =  metadata_file.exists()

            # remove_system_files(self.mountpoint)
            metadata_file.touch()
            
            # hidden files present
            self.current_content["system_files"] = any(
                item.name.startswith('.') 
                for item in Path(self.mountpoint).iterdir()
            )

            # TEMP: dont do this as slow while testing
            # self.checksum = self.compute_checksum()  # Compute actual checksum
            # self.stored_checksum = self.load_stored_checksum()  # Load stored checksum
            # self.is_checksum_valid = self.checksum_matches()  # Check if they match
            # logging.debug(f"Stored checksum {self.stored_checksum}")
            # logging.debug(f"Calcul checksum {self.checksum}")


            # read/write speed

            # capacity


            # draft = MasterDraft(config=None, settings=None, isbn=self.current_content["isbn"], sku=None, author=None, title=None, expected_count=None, input_folder=None)
            # self.draft = draft
            self.ui_context.update_isbn(self.current_content["isbn"])
            
            logging.debug(f"Set UI to use isbn {self.current_content["isbn"]}")

        except Exception as e:
            logging.error(f"Error loading current content of block: {e}")

        return

    def is_master(self):
        """
        Checks if the USB drive contains the required master structure.
        Returns True if all required directories exist, otherwise False.
        """
        required_dirs = ["tracks", "bookInfo"]
        
        return all((self.mountpath / directory).is_dir() for directory in required_dirs)



    
    def __repr__(self):
        return f"USBDrive(mountpoint={self.mountpath}, capacity={self.capacity:.2f}GB)"

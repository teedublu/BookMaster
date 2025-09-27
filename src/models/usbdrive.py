import psutil
import os, sys
import re
import logging
import time
import threading
import subprocess
import pathlib
import hashlib, shlex
from natsort import natsorted
from utils import compute_sha256
from pathlib import Path
from utils import MasterValidator
from models import MasterDraft  # Import Master class

_SLICE_RE = re.compile(r"^/dev/r?disk(\d+)(s\d+)?$")
DD_SUMMARY_RE = re.compile(r"(?P<bytes>\d+)\s+bytes transferred in\s+(?P<secs>[0-9.]+)\s+secs\s+\((?P<bps>\d+)\s+bytes/sec\)")

class USBDrive:
    def __init__(self, mountpoint, device_path=None, ui_context=None):
        """
        Initialize USBDrive with its mountpoint.
        """
        self.mountpoint = Path(mountpoint) #eg /Volumes/AA11111AA
        self.device_path = device_path or self.get_device_path()  # eg "/dev/disk4"
        self.capacity = self.get_capacity()
        self.properties = self.drive_properties() # contains capacity, device_path etc so could use from here
        self.ui_context = ui_context
        self.speed = None  # To be determined via test
        self.current_content = {}
        self.is_master = self.is_master()
        self.checksum = None
        self.stored_checksum = None
        self.is_checksum_valid = None
        self.ui_context = ui_context
        logging.debug(f"USBDrive found mountpoint:{self.mountpoint} device_path:{self.device_path} properties: {self.properties}")
        
        # if self.is_master :
        #     self.checksum = self.compute_checksum()  # Compute actual checksum
        #     self.stored_checksum = self.load_stored_checksum()  # Load stored checksum
        #     self.is_checksum_valid = self.checksum_matches()  # Check if they match
        #     logging.debug(f"Inserted drive is likely Master checksum:{self.is_checksum_valid}")

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

    def drive_properties(self):
        """
        Retrieves native properties of a USB drive using psutil, including whether it's a single volume.

        Returns:
            dict: {
                "device_info": sdiskpart object,
                "disk_usage": sdiskusage object,
                "is_single_volume": bool
            }
        """
        mountpoint = str(self.mountpoint).rstrip("/")  # Ensure string & remove trailing slash
        logging.debug(f"Checking properties for mountpoint: {mountpoint}")

        # Print all available mountpoints for debugging
        all_partitions = psutil.disk_partitions(all=True)
        logging.debug(f"Available Partitions: {[p.mountpoint for p in all_partitions]}")

        device_info = None

        # Find the device info based on mountpoint
        non_system_parts = [part for part in all_partitions if "/System/" not in part.mountpoint]

        for part in non_system_parts:
            logging.debug(f"Checking partition: {part.mountpoint} (Device: {part.device})")
            if part.mountpoint.rstrip("/") == mountpoint:
                device_info = part  # Native psutil structure
                break

        if not device_info:
            logging.warning(f"⚠️ Device not found for mountpoint: {mountpoint}")
            return None

        try:
            disk_usage = psutil.disk_usage(mountpoint)  # Get disk space details
        except Exception as e:
            logging.warning(f"❌ Failed to get disk usage for {mountpoint}: {e}")
            disk_usage = None

        # **Determine if it's a single volume**
        device_path = device_info.device  # Example: "/dev/disk5s1"
        match = re.match(r'/dev/disk(\d+)', device_path)  # Extract base disk ID

        if match:
            base_disk = f"/dev/disk{match.group(1)}"  # Example: "/dev/disk5"
            related_partitions = [p for p in all_partitions if p.device.startswith(base_disk)]
            is_single_volume = len(related_partitions) == 1  # True if only one partition exists
        else:
            logging.warning(f"⚠️ Unable to determine base device from {device_path}")
            is_single_volume = None

        properties = {
            "device_info": device_info,  # Returns the native psutil structure
            "disk_usage": disk_usage,  # Returns total, used, and free space
            "is_single_volume": is_single_volume  # True if it's the only partition
        }

        logging.debug(f"✅ Drive Properties for {mountpoint}: {properties}")
        return properties

    def _normalize_to_raw_whole(devnode: str) -> str | None:
        """
        Accepts /dev/disk4, /dev/rdisk4, /dev/disk4s1, /dev/rdisk4s1
        Returns /dev/rdisk4 (raw whole disk) or None if unrecognized.
        """
        m = _SLICE_RE.match(devnode)
        if not m:
            return None
        num = m.group(1)
        return f"/dev/rdisk{num}"

    def _normalize_to_nodes(self, devnode: str):
        """
        Accepts /dev/disk4, /dev/rdisk4, /dev/disk4s1, /dev/rdisk4s1
        Returns (diskutil_node, raw_whole) -> (/dev/disk4, /dev/rdisk4)
        """
        m = _SLICE_RE.match(devnode)
        if not m:
            raise RuntimeError(f"Unrecognized device node: {devnode}")
        num = m.group(1)
        return f"/dev/disk{num}", f"/dev/rdisk{num}"

    def get_device_path(self) -> str | None:
        """
        macOS only: map this mountpoint -> /dev/rdiskX (whole disk).
        """
        try:
            result = subprocess.run(
                ["diskutil", "info", self.mountpoint],
                capture_output=True, text=True, check=True
            )
            dev_node = None
            for line in result.stdout.splitlines():
                if line.strip().startswith("Device Node:"):
                    dev_node = line.split(":", 1)[1].strip()
                    break

            if not dev_node:
                logging.warning(f"diskutil did not report a Device Node for {self.mountpoint}")
                return None

            raw_whole = _normalize_to_raw_whole(dev_node)
            if raw_whole and os.path.exists(raw_whole):
                return raw_whole

            return dev_node  # fallback, but may be a slice
        except subprocess.CalledProcessError as e:
            logging.error(f"Failed to retrieve device path for {self.mountpoint}: {e}")
            return None

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

    def get_capacity(self):
        """Check and return total capacity of the USB drive."""
        try:
            usage = psutil.disk_usage(self.mountpoint)
            return usage.total / (1024 ** 3)  # Convert bytes to GB
        except Exception as e:
            print(f"Error getting capacity of {self.mountpoint}: {e}")
            return None

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
        
        return all((self.mountpoint / directory).is_dir() for directory in required_dirs)



    
    def __repr__(self):
        return f"USBDrive(mountpoint={self.mountpoint}, capacity={self.capacity:.2f}GB)"

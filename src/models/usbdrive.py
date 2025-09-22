import psutil
import os
import re
import logging
import time
import threading
import subprocess
import pathlib
import hashlib
from natsort import natsorted
from utils import compute_sha256
from pathlib import Path
from utils import MasterValidator
from models import MasterDraft  # Import Master class

DD_SUMMARY_RE = re.compile(
    r"(?P<bytes>\d+)\s+bytes transferred in\s+(?P<secs>[0-9.]+)\s+secs\s+\((?P<bps>\d+)\s+bytes/sec\)"
)

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

    def get_device_path(self):
        """
        Find the raw device path corresponding to this mountpoint.

        Returns:
            str: The raw device path (e.g., '/dev/disk2') or None if not found.
        """
        for part in psutil.disk_partitions(all=True):
            if part.mountpoint == self.mountpoint:
                return part.device  # Example: "/dev/disk2s1"

        logging.warning(f"Could not find device path for {self.mountpoint}")
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

        try:
            # Unmount USB drive to prevent conflicts
            logging.info(f"Unmounting device {self.device_path}...")
            subprocess.run(["diskutil", "unmountDisk", self.device_path], check=True)

            # Write the .img to the raw device, NOT the mountpoint
            logging.info(f"Writing image {image_str} to {self.device_path}...")

            dd_command = [
                "dd",
                f"if={image_str}",
                f"of={self.device_path}",  # Use the raw device path
                "bs=4M",
                "status=progress"
            ]

            if use_sudo:
                dd_command.insert(0, "sudo")

            proc = subprocess.run(dd_command, check=True, capture_output=True, text=True)

            if proc.returncode != 0:
                raise RuntimeError(proc.stderr or proc.stdout)

            m = DD_SUMMARY_RE.search(proc.stderr)
            if not m:
                raise RuntimeError("Could not parse dd output for write speed")

            dd_bytes = int(m.group("bytes"))
            dd_secs = float(m.group("secs"))
            dd_bps = int(m.group("bps"))
            dd_MBps = dd_bps / (1024 * 1024)

            logging.info(f"Disk image written successfully at {dd_MBps: .0f} MBps.")

        except subprocess.CalledProcessError as e:
            logging.error(f"Command failed: {e.cmd}")
            logging.error(f"Error message: {e.stderr}")
            raise RuntimeError(f"An error occurred during execution: {e}")

        except KeyboardInterrupt:
            logging.error("Process interrupted by user. Aborting write operation.")
            raise RuntimeError("Disk image writing aborted.")

        except Exception as e:
            logging.error(f"Unexpected error: {e}")
            raise RuntimeError(f"An unexpected error occurred: {e}")

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

import psutil
import os
import logging
import time
import threading
import subprocess
import pathlib
# from utils import remove_system_files
from pathlib import Path

class USBDrive:
    def __init__(self, mountpoint, device_path=None):
        """
        Initialize USBDrive with its mountpoint.
        """
        self.mountpoint = mountpoint
        self.device_path = device_path or self.get_device_path()  # Get raw device if not provided
        self.capacity = self.get_capacity()
        self.speed = None  # To be determined via test
        self.current_content = {}
    
    def get_device_path(self):
        """
        Find the raw device path corresponding to this mountpoint.

        Returns:
            str: The raw device path (e.g., '/dev/disk2') or None if not found.
        """
        try:
            result = subprocess.run(
                ["diskutil", "info", self.mountpoint],
                capture_output=True, text=True, check=True
            )
            for line in result.stdout.splitlines():
                if "Device Node" in line:
                    return line.split(":")[-1].strip()
        except subprocess.CalledProcessError as e:
            logging.error(f"Failed to retrieve device path for {self.mountpoint}: {e}")
        return None  # Return None if the device path couldn't be determined


    def write_disk_image(self, image_path, use_sudo=True):
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
        if not os.path.isfile(image_path):
            raise ValueError(f"The image file does not exist: {image_path}")
        if not image_path.endswith(".img"):
            raise ValueError("The provided image path does not have a .img extension.")

        if not self.device_path:
            raise RuntimeError("Could not determine the raw device path.")

        try:
            # Unmount USB drive to prevent conflicts
            logging.info(f"Unmounting device {self.device_path}...")
            subprocess.run(["diskutil", "unmountDisk", self.device_path], check=True)

            # Write the .img to the raw device, NOT the mountpoint
            logging.info(f"Writing image {image_path} to {self.device_path}...")

            dd_command = [
                "dd",
                f"if={image_path}",
                f"of={self.device_path}",  # Use the raw device path
                "bs=4M",
                "status=progress"
            ]

            if use_sudo:
                dd_command.insert(0, "sudo")

            subprocess.run(dd_command, check=True)

            logging.info("Disk image written successfully.")

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


            # read/write speed

            # capacity
            
        except Exception as e:
            logging.error(f"Error loading current content of block: {e}")

        return

    
    def __repr__(self):
        return f"USBDrive(mountpoint={self.mountpoint}, capacity={self.capacity:.2f}GB)"

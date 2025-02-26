import psutil
import os
import time
import threading
import subprocess
import platform
import hashlib
import logging
import traceback
from models import USBDrive

class USBHub:
    def __init__(self, callback=None, mountpoint="/Volumes"):
        """
        Monitor and manage connected USB drives.

        Args:
            callback (function): Function to call when drives are updated.
            mountpoint (str): Base directory where USB drives are mounted.
                              Defaults to '/Volumes' (macOS). Use '/media' or '/mnt' on Linux.
        """
        self.mountpoint = mountpoint
        self.drives = {}
        self.drive_list = []
        self.callback = callback if callable(callback) else lambda x: None
        self.lock = threading.Lock()  # Ensure thread safety

        self.monitor_thread = threading.Thread(target=self.monitor_drives, daemon=True)
        self.monitor_thread.start()

    @property
    def has_available_drive(self):
        """Check if at least one USB drive is connected."""
        return bool(self.drives)

    @property
    def first_available_drive(self):
        """Return the first available USBDrive object, or None if no drive is found."""
        return next(iter(self.drives.values()), None)


    def get_usb_drives(self):
        """
        Detect connected USB drives and return them as a dictionary.

        Returns:
            dict: {mountpoint: USBDrive} of available drives.
        """
        drives = {}

        try:
            for part in psutil.disk_partitions(all=False):
                if part.mountpoint.startswith(self.mountpoint) and part.fstype in ("exfat", "vfat", "msdos"):
                    device_path = self.get_device_path(part.mountpoint)

                    if device_path:
                        if part.mountpoint in self.drives:
                            # Reuse existing USBDrive instance
                            drives[part.mountpoint] = self.drives[part.mountpoint]
                        else:
                            # Create new USBDrive instance only for newly detected drives
                            logging.debug(f"Creating new USB drive: {part.mountpoint} _ {device_path}")
                            drives[part.mountpoint] = USBDrive(part.mountpoint, device_path)

        except Exception as e:
            tb = traceback.extract_tb(e.__traceback__)[-1]
            logging.debug(f"Error getting USB drives at {tb.filename}:{tb.lineno}: {e}")

        return drives

    def monitor_drives(self):
        """Continuously monitor for USB insertions/removals."""
        while True:
            with self.lock:
                current_drives = self.get_usb_drives()
                new_drives = {d: drive for d, drive in current_drives.items() if d not in self.drives}
                removed_drives = {d: drive for d, drive in self.drives.items() if d not in current_drives}

                # Update stored drives (only modifying what's needed)
                for mountpoint, drive in new_drives.items():
                    print(f"🔌 New drive detected: {mountpoint}")
                    self.drives[mountpoint] = drive  # Store the new drive

                for mountpoint in removed_drives:
                    print(f"💨 Drive removed: {mountpoint}")
                    del self.drives[mountpoint]  # Remove disconnected drives

                self.update_drive_list()

            time.sleep(5)  # Polling interval

    


    def get_device_path(self, mountpoint):
        """
        Find the raw device path corresponding to a given mountpoint.

        Args:
            mountpoint (str): The filesystem path (e.g., '/Volumes/MyUSB').

        Returns:
            str: The raw device path (e.g., '/dev/disk2') or None if not found.
        """
        try:
            result = subprocess.run(
                ["diskutil", "info", mountpoint],
                capture_output=True, text=True, check=True
            )
            for line in result.stdout.splitlines():
                if "Device Node" in line:
                    return line.split(":")[-1].strip()
        except subprocess.CalledProcessError as e:
            logging.error(f"Failed to retrieve device path for {mountpoint}: {e}")
        return None  # Return None if the device path couldn't be determined

    def update_drive_list(self):
        """Update the drive list and notify the UI."""
        self.drive_list = list(self.drives.keys())
        self.callback(self.drive_list)  # Notify UI of changes

    def get_drive_list(self):
        """Expose the list of connected drives."""
        return self.drive_list

    def eject_disk(disk_identifier):
        """
        Ejects a disk on macOS using diskutil.
        
        :param disk_identifier: The identifier of the disk (e.g., "disk2", "disk3s1").
        :return: True if successful, False otherwise.
        """
        try:
            result = subprocess.run(["diskutil", "eject", disk_identifier], capture_output=True, text=True, check=True)
            print(result.stdout.strip())
            return True
        except subprocess.CalledProcessError as e:
            print(f"Error ejecting {disk_identifier}: {e.stderr.strip()}")
            return False
            
    def erase_removable_drive(device_path, filesystem="exfat", label="USB_DRIVE"):
        """
        Erases a removable drive and formats it with the specified filesystem.

        Args:
            device_path (str): The raw device path (e.g., '/dev/disk2' on macOS, '/dev/sdb' on Linux).
            filesystem (str): Filesystem type (default: 'exfat').
            label (str): Volume label after formatting (default: 'USB_DRIVE').

        Returns:
            bool: True if successful, False otherwise.
        """
        system_os = platform.system()

        try:
            # Step 1: Unmount the drive
            logging.info(f"Unmounting {device_path}...")
            if system_os == "Darwin":  # macOS
                subprocess.run(["diskutil", "unmountDisk", device_path], check=True)
            elif system_os == "Linux":
                subprocess.run(["umount", device_path], check=True)

            # Step 2: Format the drive
            logging.info(f"Formatting {device_path} as {filesystem}...")
            if system_os == "Darwin":  # macOS
                subprocess.run(["diskutil", "eraseDisk", filesystem, label, device_path], check=True)
            elif system_os == "Linux":
                if filesystem.lower() == "exfat":
                    subprocess.run(["mkfs.exfat", "-n", label, device_path], check=True)
                elif filesystem.lower() == "vfat":
                    subprocess.run(["mkfs.vfat", "-n", label, device_path], check=True)
                elif filesystem.lower() == "ext4":
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

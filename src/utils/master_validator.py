import os
from utils import compute_sha256
import logging
from config.config import Config
from settings import (
    load_settings, save_settings
)


class MasterValidator:
    """
    Validates a master structure to ensure it follows the required format on a USB drive.
    """

    def __init__(self, usb_drive, expected_count=None, expected_isbn=None):
        """
        :param usb_drive: USBDrive instance representing the mounted USB device.
        :param expected_count: Expected number of track files.
        :param expected_isbn: Expected ISBN value.
        """
        self.usb_drive = usb_drive
        self.expected_count = expected_count
        self.expected_isbn = expected_isbn
        self.file_isbn = None
        self.file_count = None
        self.errors = []
        logging.info(f"MasterValidator created")
        self.validate()

    def validate(self):
        from models import Master # needs to be in function to prevent circular imports
        """Runs all validation checks and returns a summary."""
        self.errors = []  # Reset errors before validation

        settings = load_settings()
        config = Config()  # Assuming Config can accept a debug flag

        logging.debug(f"creating candidate master {self.usb_drive.mountpoint}")
        self.candidate_master = Master.from_device(config, settings, self.usb_drive.mountpoint)

        self.check_path_exists()
        self.check_tracks_folder()
        self.check_bookinfo_id()
        self.check_checksum()

        logging.info(f"Validation performed, errors found: {self.errors}")

        return len(self.errors) == 0, self.errors  # Return validation status and errors

    def check_path_exists(self):
        """Ensure the USB drive mount path exists."""
        if not os.path.exists(self.usb_drive.mountpoint):
            self.errors.append(f"USB drive path does not exist: {self.usb_drive.mountpoint}")

    def check_tracks_folder(self):
        """Check if the 'tracks' folder exists and contains the correct number of files."""
        tracks_path = os.path.join(self.usb_drive.mountpoint, "tracks")

        if not os.path.isdir(tracks_path):
            self.errors.append("Missing expected 'tracks' folder.")
            return

        # Count only the files (ignore directories)
        track_files = [f for f in os.listdir(tracks_path) if os.path.isfile(os.path.join(tracks_path, f))]
        self.track_count = len(track_files)

        if self.track_count != self.expected_count:
            if self.expected_count: #only check if passed explicit value
                self.errors.append(f"Expected {self.expected_count} track files, but found {self.track_count} in '{tracks_path}'.")

    def check_bookinfo_id(self):
        """Check that the ISBN in 'bookinfo/id.txt' matches the expected value."""
        bookinfo_path = os.path.join(self.usb_drive.mountpoint, "bookinfo")
        id_txt_path = os.path.join(bookinfo_path, "id.txt")

        if not os.path.isdir(bookinfo_path):
            self.errors.append("Missing 'bookinfo' directory.")
            return

        if not os.path.isfile(id_txt_path):
            self.errors.append("Missing 'id.txt' in 'bookinfo' directory.")
            return

        # Read ISBN from file
        with open(id_txt_path, "r", encoding="utf-8") as f:
            self.file_isbn = f.read().strip()

        if self.file_isbn != self.expected_isbn:
            if self.expected_isbn: #only check if passed explicit value
                self.errors.append(f"ISBN mismatch: Expected {self.expected_isbn}, but found {self.file_isbn} in 'id.txt'.")

    def check_checksum(self):
        """Check that the checksum.txt file exists and matches computed checksums."""
        checksum_path = os.path.join(self.usb_drive.mountpoint, "checksum.txt")

        if not os.path.isfile(checksum_path):
            self.errors.append("Missing 'checksum.txt' in the root of the USB drive.")
            return

        # Read expected checksums
        expected_checksums = {}
        with open(checksum_path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split("  ")
                if len(parts) == 2:
                    expected_checksums[parts[1]] = parts[0]

        # Compute actual checksums
        actual_checksums = {}
        for root, _, files in os.walk(self.usb_drive.mountpoint):
            for file in files:
                file_path = os.path.join(root, file)
                if file == "checksum.txt":  # Skip checksum file itself
                    continue
                actual_checksums[file] = compute_sha256(file_path)

        # Compare expected vs actual
        for file, expected_hash in expected_checksums.items():
            actual_hash = actual_checksums.get(file)
            if actual_hash is None:
                self.errors.append(f"File '{file}' listed in checksum.txt is missing.")
            elif actual_hash != expected_hash:
                self.errors.append(f"Checksum mismatch for '{file}': expected {expected_hash}, got {actual_hash}.")

        # Check for unexpected files
        for file in actual_checksums.keys():
            if file not in expected_checksums:
                self.errors.append(f"⚠️ Unexpected file '{file}' not listed in checksum.txt.")

    



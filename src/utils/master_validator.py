import os
from utils import compute_sha256, remove_system_files
from pathlib import Path
import logging
import subprocess
import json
from config.config import Config
from settings import (
    load_settings, save_settings
)


class MasterValidator:
    """
    Validates a master structure to ensure it follows the required format on a USB drive.
    """

    def __init__(self, usb_drive, tests=None, expected_count=None, expected_isbn=None):
        """
        :param usb_drive: USBDrive instance representing the mounted USB device.
        :param expected_count: Expected number of track files.
        :param expected_isbn: Expected ISBN value.
        """
        self.usb_drive = usb_drive
        self.expected_isbn = expected_isbn
        self.usb_drive_tests_var = None
        self.file_isbn = None
        self.file_count_expected = expected_count
        self.is_clean = None
        self.errors = []
        self.tests = tests
        logging.info(f"MasterValidator created from {self.usb_drive} with tests={tests}")
        self.validate()

    def validate(self):
        from models import Master # needs to be in function to prevent circular imports
        """Runs all validation checks and returns a summary."""
        self.errors = []  # Reset errors before validation

        settings = load_settings()
        config = Config()

        logging.debug(f"creating candidate master {self.usb_drive.mountpoint} settings={json.dumps(settings, indent=2)} config={config}")
        settings["past_master"] = {}

        self.candidate_master = Master.from_device(config, settings, self.usb_drive.mountpoint, self.tests) #from_device defines the checks to be made
        
        # self.candidate_master.lookup_isbn(self.candidate_master.isbn)

        self.check_path_exists()
        self.check_tracks_folder()
        self.check_bookinfo_id()
        self.check_checksum()

        
        self.is_clean = self.ensure_metadata_never_index() & remove_system_files(self.usb_drive.mountpoint)
        
        logging.info(f"Validation performed, errors found: {self.errors}")
        logging.info(f"|--- title: {self.candidate_master.title}")
        logging.info(f"|--- isbn: {self.candidate_master.isbn}")
        logging.info(f"|--- sku: {self.candidate_master.sku}")
        logging.info(f"|--- duration: {self.candidate_master.duration}")
        logging.info(f"|--- USB is_clean: {self.is_clean}")
        logging.info(f"|--- USB is_single_volume: {self.usb_drive.properties.get("is_single_volume")}")

        logging.info (self.candidate_master)

        logging.info (f"Overall status {self.candidate_master.validate()}")
        
        # self.candidate_master.master_tracks.reencode_all_in_place()

        return len(self.errors) == 0, self.errors  # Return validation status and errors

    def check_path_exists(self):
        """Ensure the USB drive mount path exists."""
        if not os.path.exists(self.usb_drive.mountpoint):
            self.errors.append(f"USB drive path does not exist: {self.usb_drive.mountpoint}")

    def ensure_metadata_never_index(self):
        """
        Ensures that the `.metadata_never_index` file exists in the given drive to prevent Spotlight indexing.
        
        Args:
            drive (str or Path): The root directory of the drive.
        """

        drive_path = Path(self.usb_drive.mountpoint)  # Ensure it's a Path object
        metadata_file = drive_path / ".metadata_never_index"  # Construct path

        if metadata_file.exists():
            logging.info(".metadata_never_index already exists; no need to create it.")
        else:
            try:
                metadata_file.touch(exist_ok=True)  # Create empty file
                logging.info("Created .metadata_never_index to prevent Spotlight indexing.")
            except PermissionError:
                logging.warning("Failed to create .metadata_never_index due to permissions.")
                return False

        return True

    def check_tracks_folder(self):
        """Check if the 'tracks' folder exists and contains the correct number of files."""

        tracks_path = Path(self.usb_drive.mountpoint) / "tracks"

        if not tracks_path.is_dir():
            self.errors.append("Missing expected 'tracks' folder.")
            return
        if not self.candidate_master:
            self.errors.append("Missing Candidate Master.")
            return

        # Count only files (ignoring subdirectories)
        file_count_observed = sum(1 for f in tracks_path.iterdir() if f.is_file())
        file_count_expected = self.candidate_master.file_count_expected

        if file_count_observed != file_count_expected:
            self.errors.append(f"Expected {file_count_expected} track files, but found {file_count_observed} in '{tracks_path}'")
        else:
            logging.info(f"Found {file_count_observed} (expecting {file_count_expected}) in '{tracks_path}'")

    def check_bookinfo_id(self):
        """Check that the ISBN in 'bookinfo/id.txt' matches the expected value."""
        
        id_txt_path = Path(self.usb_drive.mountpoint) / "bookinfo" / "id.txt"

        if not id_txt_path.parent.is_dir():
            self.errors.append("Missing 'bookinfo' directory.")
            return

        if not id_txt_path.exists():
            self.errors.append("Missing 'id.txt' in 'bookinfo' directory.")
            return

        # Read and strip the ISBN
        self.file_isbn = id_txt_path.read_text(encoding="utf-8").strip()

        # Validate ISBN if expected ISBN is provided
        if self.candidate_master and self.file_isbn != self.candidate_master.isbn:
            self.errors.append(f"ISBN mismatch: Expected {self.candidate_master.isbn}, but found {self.file_isbn} in 'id.txt'.")
        else:
            logging.info(f"Found ID {self.file_isbn} (expecting {self.candidate_master.isbn}) in {id_txt_path.parent}.")

    def check_checksum(self):
        """Returns True if expected and actual checksums match."""
        return self.candidate_master.checksum_file_value == self.candidate_master.checksum_computed

    def check_checksumOLD(self):
        """Check that the checksum.txt file exists and matches computed checksums."""
        checksum_path = os.path.join(self.usb_drive.mountpoint, "bookinfo", "checksum.txt")

        if not os.path.isfile(checksum_path):
            self.errors.append("Missing 'checksum.txt' in the /bookInfo folder on the USB drive.")
            return

        # Read expected checksums
        expected_checksums = {}
        with open(checksum_path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split("  ")
                if len(parts) == 2:
                    expected_checksums[parts[1]] = parts[0]

        file_paths = []
        for root, _, files in os.walk(self.usb_drive.mountpoint):
            for file in files:
                if file == "checksum.txt":
                    continue
                full_path = Path(root) / file
                file_paths.append(full_path)

        usb_checksum = compute_sha256(file_paths)


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
                self.errors.append(f"Unexpected file '{file}' not listed in checksum.txt.")

    




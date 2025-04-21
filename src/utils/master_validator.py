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

    def __init__(self, master):
        """
        :param usb_drive: USBDrive instance representing the mounted USB device.
        :param expected_count: Expected number of track files.
        :param expected_isbn: Expected ISBN value.
        """
        self.master = master
        self.usb_drive = None
        self.expected_isbn = None
        self.usb_drive_tests_var = None
        self.file_isbn = None
        self.file_count_expected = None
        self.is_clean = None
        self.errors = []
        self.tests = None
        logging.info(f"MasterValidator created from {self.usb_drive} with tests={self.tests}")
        self.validate()

    def validate(self):
        from models import Master # needs to be in function to prevent circular imports
        """Runs all validation checks and returns a summary."""
        self.errors = []  # Reset errors before validation

        settings = self.master.settings
        config = self.master.config

        # logging.debug(f"creating candidate master settings={json.dumps(settings, indent=2)} config={config}")
        # settings["past_master"] = {}

        # self.master = Master.from_device(config, settings, self.usb_drive.mountpoint, self.tests) #from_device defines the checks to be made
        
        # self.master.lookup_isbn(self.master.isbn)

        self.check_path_exists()
        self.check_tracks_folder()
        self.check_bookinfo_id()
        self.check_checksum()

        
        # self.is_clean = self.ensure_metadata_never_index() & remove_system_files(self.usb_drive.mountpoint)
        is_single_volume = False
        if getattr(self.usb_drive, "properties", None) and isinstance(self.usb_drive.properties, dict):
            is_single_volume = self.usb_drive.properties.get("is_single_volume", False)

        logging.info(f"Validation performed, errors found: {self.errors}")
        logging.info(f"|--- title: {self.master.title}")
        logging.info(f"|--- isbn: {self.master.isbn}")
        logging.info(f"|--- sku: {self.master.sku}")
        logging.info(f"|--- duration: {self.master.duration}")
        logging.info(f"|--- USB is_clean: {self.is_clean}")
        logging.info(f"|--- USB is_single_volume: {is_single_volume}")

        logging.info (self.master)
        
        # self.master.master_tracks.reencode_all_in_place()

        return len(self.errors) == 0, self.errors  # Return validation status and errors

    def check_path_exists(self):
        """Ensure the USB drive mount path exists."""
        if not self.usb_drive: 
            self.errors.append(f"USB drive not prvided")
            return
        if not os.path.exists(self.usb_drive.mountpoint):
            self.errors.append(f"USB drive path does not exist: {self.usb_drive.mountpoint}")

    def ensure_metadata_never_index(self):
        """
        Ensures that the `.metadata_never_index` file exists in the given drive to prevent Spotlight indexing.
        
        Args:
            drive (str or Path): The root directory of the drive.
        """

        drive_path = self.master.master_path
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

        tracks_path = self.master.master_path / "tracks"

        if not tracks_path.is_dir():
            self.errors.append("Missing expected 'tracks' folder.")
            return
        
        # Count only files (ignoring subdirectories)
        file_count_observed = int(sum(1 for f in tracks_path.iterdir() if f.is_file()))
        file_count_expected = int(self.master.file_count_expected)

        if file_count_observed != file_count_expected:
            self.errors.append(f"Expected {file_count_expected} track files, but found {file_count_observed} in '{tracks_path}'")
        else:
            logging.info(f"Found {file_count_observed} (expecting {file_count_expected}) in '{tracks_path}'")

    def check_bookinfo_id(self):
        """Check that the ISBN in 'bookinfo/id.txt' matches the expected value."""
        
        id_txt_path = self.master.master_path / "bookinfo" / "id.txt"

        if not id_txt_path.parent.is_dir():
            self.errors.append("Missing 'bookinfo' directory.")
            return

        if not id_txt_path.exists():
            self.errors.append("Missing 'id.txt' in 'bookinfo' directory.")
            return

        # Read and strip the ISBN
        self.file_isbn = id_txt_path.read_text(encoding="utf-8").strip()

        # Validate ISBN if expected ISBN is provided
        if self.master and self.file_isbn != self.master.isbn:
            self.errors.append(f"ISBN mismatch: Expected {self.master.isbn}, but found {self.file_isbn} in 'id.txt'.")
        

    def check_checksum(self):
        """Returns True if expected and actual checksums match."""
        if not self.master.checksum_file_value == self.master.checksum:
            self.errors.append("Checksums mismatch.")

    
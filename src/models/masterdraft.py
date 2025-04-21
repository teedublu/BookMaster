from pathlib import Path
import pycdlib
import logging
import ffmpeg
import hashlib
import shutil
import re
from natsort import natsorted
from utils import remove_folder, compute_sha256, get_first_audiofile, get_metadata_from_audio, generate_sku, generate_isbn, parse_time_to_minutes
from .tracks import Tracks
from models import Master
from .diskimage import DiskImage
from constants import MAX_DRIVE_SIZE

class MasterDraft:
    """
    Represents the draft of master audiobook collection, managing inputs
    Does not process files just ensures valid input
    """
    def __init__(self, config=None, settings=None, isbn=None, sku=None, author=None, title=None, expected_count=None, input_folder=None, skip_encoding=False):
        self.config = config # config of audio settings 
        self.settings = settings # UI and file locations NOT NEEDED should be called inputs
        self.params = getattr(self.config, "params", {}) # NOT NEEDED
        # self.output_path = Path(settings.get("output_folder","default_output")) # NOT NEEDED
        self.input_folder = None  # Tracks: Raw publisher files Tracks
        # self.processed_tracks = None  # Tracks: Encoded and cleaned tracks # NOT NEEDED
        # self.master_tracks = None  # Tracks: Loaded from either USB drive or disk image # NOT NEEDED
        # self.master_structure = None # NOT NEEDED
        self.isbn = isbn
        self.sku = sku
        self.title = title
        self.author = author
        self.file_count_expected = expected_count if expected_count else 0
        self.file_count_observed = 0
        self._duration = 0
        self._checksum_computed = None
        self.status = None
        self.skip_encoding = False
        self.tracks = None
        
        # self.lookup_csv = settings.get("lookup_csv", False)
        # self.skip_encoding = settings.get("skip_encoding", False) # useful for speeding up debugging
        
    
        logging.debug(f"Initiating new MasterDraft {self}")
        
        # Logger setup
        self.logger = logging.getLogger(__name__)
    
    def __str__(self):
        """
        Returns a string representation of the Master instance, including its tracks,
        structure, and metadata files.
        """
        return (
            f"MasterDraft:\n"
            f"Title: {self.title}\n"
            f"Author: {self.author}\n"
            f"ISBN: {self.isbn}\n"
            f"SKU: {self.sku}\n"
            f"Expected Files: {self.file_count_expected}\n"
            f"Observed Files: {self.file_count_observed}\n"
            f"Input Folder:{self.input_folder}"
        )
    
    @classmethod
    def from_file(cls, config, settings, file_path, tests):
        """ Alternative constructor to initialize Master from a device. """
        instance = cls(config, {})
        instance.reset_metadata_fields()
        return instance

    def load_tracks(self):
        """Loads the raw input tracks provided by the publisher."""
        logging.info(f"Loading Tracks '{self.input_folder}'")
        self.tracks = Tracks(self, self.input_folder, self.params)

    
    def reset_metadata_fields(self):
        self.isbn = ""
        self.title = ""
        self.author = ""
        self.sku = ""
        self.duration = 0

    from pathlib import Path

    def validate(self):
        errors = []
        # valid_formats = self.config.get("output_structure",None)

        # Require all basic metadata
        if not self.isbn or not isinstance(self.isbn, str):
            errors.append("Missing or invalid ISBN")
        if not self.title or not isinstance(self.title, str):
            errors.append("Missing or invalid title")
        if not self.author or not isinstance(self.author, str):
            errors.append("Missing or invalid author")
        if not self.sku or not isinstance(self.sku, str):
            errors.append("Missing or invalid SKU")

        input_path = Path(self.input_folder) if self.input_folder else None

        # Check for presence of audio files in supported formats
        if not input_path or not input_path.exists():
            errors.append(f"Input folder does not exist: {input_path}")
        else:
            audio_files = [f for f in input_path.iterdir() if f.suffix.lower() in self.config.params.get("valid_formats",None)]
            if not audio_files:
                errors.append(f"No valid audio files found in input folder: {input_path}")

        # Compare file count if expected is specified
        if getattr(self, "file_count_expected", None) is not None and getattr(self, "file_count_expected", None) > 0:
            actual = len(audio_files) if input_path and input_path.exists() else 0
            if actual != self.file_count_expected:
                errors.append(f"Expected {self.file_count_expected} files, found {actual}")

        if errors:
            return '-- ' + '\n-- '.join(errors)

        return None
 
    def calculate_encoding_for_drive_limit(self):
        """
        Determines if the total size of the tracks fits on the configured max drive size.
        If not, calculates the required encoding bitrate to make it fit.
        """

        # Fetch values from config
        config = self.config.params
        max_drive_size = int(config["max_drive_size"])  # e.g., 1_000_000_000 for ~1GB
        current_bit_rate = int(config["encoding"]["bit_rate"])  # e.g., 96000
        current_size_bytes = self.tracks.total_target_size

        if current_size_bytes <= max_drive_size:
            self.logger.info(
                f"Tracks fit within drive limit: {current_size_bytes} bytes "
                f"({current_size_bytes / (1024**2):.2f} MB). No encoding changes required."
            )
            return current_bit_rate

        # Calculate required bitrate to fit
        reduction_factor = max_drive_size / current_size_bytes
        required_bit_rate = int(current_bit_rate * reduction_factor)

        # Optional range limits – could also be pulled from config if needed
        min_reasonable_bitrate = 32000  # Consider config if you want it dynamic
        adjusted_bit_rate = max(min_reasonable_bitrate, min(required_bit_rate, current_bit_rate))

        if adjusted_bit_rate == current_bit_rate:
            self.logger.warning(
                f"Tracks exceed drive size ({current_size_bytes / (1024**2):.2f} MB), "
                "but reducing bitrate further may cause quality loss."
            )
        else:
            self.logger.warning(
                f"Tracks exceed drive size ({current_size_bytes / (1024**2):.2f} MB). "
                f"Suggest reducing bitrate from {current_bit_rate} to {adjusted_bit_rate}."
            )

        return adjusted_bit_rate

    def reset(self):
        self.isbn = ""
        self.title = ""
        self.author = ""
        self.sku = ""
        self.duration = 0

    def update_settings(self):
        self.settings.update({
            "isbn": self.isbn,
            "sku": self.sku,
            "title": self.title,
            "author": self.author,
            "input_folder": self.input_folder,
            "file_count_expected": self.file_count_expected,
            "skip_encoding": self.skip_encoding
        })

    def to_master(self, output_path: Path) -> Master:
        self.validate()
        self.calculate_encoding_for_drive_limit()
        self.update_settings()
        # TODO Unpick the "past_master" storage and keep it at root
        master = Master(config=self.config, settings=self.settings, input_tracks=self.tracks)

        return master

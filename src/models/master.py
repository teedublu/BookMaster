from pathlib import Path
import pycdlib
import logging
from .tracks import Tracks

class Master:
    """
    Represents the master audiobook collection, managing files and metadata.
    """
    def __init__(self, config):
        self.config = config
        self.input_tracks = None  # Raw publisher files
        self.processed_tracks = None  # Encoded and cleaned tracks
        self.master_tracks = None  # Loaded from either USB drive or disk image
        self.root = Path(self.config.output_folder)

        # Direct properties instead of dictionary fields
        self.isbn = ""
        self.sku = ""
        self.title = ""
        self.author = ""
        self.duration = 0.0
        self.file_count_expected = 0
        self.file_count_observed = 0
        self.status = ""
        
        # Logger setup
        self.logger = logging.getLogger(__name__)
        
        # Load previously processed files if available
        self._load_processed_tracks()
    
    def get_fields(self):
        """Returns a dictionary of all property values for UI synchronization."""
        return {
            "isbn": self.isbn,
            "sku": self.sku,
            "title": self.title,
            "author": self.author,
            "duration": self.duration,
            "file_count_expected": self.file_count_expected,
            "file_count_observed": self.file_count_observed,
            "status": self.status,
        }

    @classmethod
    def from_device(cls, config, device_path):
        """ Alternative constructor to initialize Master from a device. """
        instance = cls(config)
        instance.load_master_from_drive(device_path)
        return instance
    
    @classmethod
    def from_img(cls, config, image_path):
        """ Alternative constructor to initialize Master from a disk image using pycdlib. """
        instance = cls(config)
        instance.load_master_from_image(image_path)
        return instance

    def setup_structure(self):
        """ Ensures the directory structure is created and validated. """
        self.config.create_structure(self.root)
        self.config.validate_structure(self.root, self.file_count_observed, self.isbn)
    
    def load_input_tracks(self, input_folder):
        """Loads the raw input tracks provided by the publisher."""
        self.input_tracks = Tracks(input_folder, getattr(self.config, "params", {}))

    
    def _load_processed_tracks(self):
        """Loads previously encoded and cleaned tracks to avoid re-encoding."""
        processed_folder = self.config.processed_folder
        if Path(processed_folder).exists():
            self.processed_tracks = Tracks(processed_folder, self.config.params)
    
    def load_master_from_drive(self, drive_path):
        """Loads a previously created Master from a removable drive."""
        self.logger.info(f"Loading Master from drive: {drive_path}")
        tracks_path = Path(drive_path) / self.config.output_structure["tracks_path"]
        info_path = Path(drive_path) / self.config.output_structure["info_path"]
        
        self.master_tracks = Tracks(tracks_path or image_path, self.config.params)
        
        try:
            self.isbn = (info_path / self.config.output_structure["id_file"]).read_text().strip()
            self.file_count_expected = int((info_path / self.config.output_structure["count_file"]).read_text().strip())
            self.title = self.master_tracks.title
            self.author = self.master_tracks.author
            self.duration = self.master_tracks.duration
        except FileNotFoundError:
            self.logger.error("Required metadata files (id.txt, count.txt) missing in bookInfo.")
            raise
    
    def load_master_from_image(self, image_path):
        """Loads a previously created Master from a disk image using pycdlib."""
        self.logger.info(f"Loading Master from disk image: {image_path}")
        iso = pycdlib.PyCdlib()
        iso.open(image_path)
        
        try:
            file_list = iso.listdir('/')
            self.logger.info(f"Found files in image: {file_list}")
            
            if "bookInfo/id.txt" in file_list:
                self.isbn = iso.open_file_from_iso("/bookInfo/id.txt").read().decode().strip()
            if "bookInfo/count.txt" in file_list:
                self.file_count_expected = int(iso.open_file_from_iso("/bookInfo/count.txt").read().decode().strip())
            
            self.logger.info(f"Loaded Master metadata - ISBN: {self.isbn}, File Count: {self.file_count_expected}")
        except Exception as e:
            self.logger.error(f"Error reading disk image: {e}")
            raise
        finally:
            iso.close()
    
    def process_tracks(self):
        """
        Processes raw input tracks into clean, encoded versions.
        Uses already processed tracks if available to avoid re-encoding.
        """
        if not self.input_tracks:
            self.logger.error("No input tracks provided.")
            raise ValueError("No input tracks provided.")

        if not self.processed_tracks:
            self.logger.info("No processed tracks found, encoding new files...")
            self._encode_tracks()
        else:
            self.logger.info("Using previously processed tracks, skipping re-encoding.")
    
    def validate_master(self):
        """Validates an existing Master from drive or disk image."""
        if self.master_tracks:
            self.logger.info("Validating Master...")
            self._validate_tracks(self.master_tracks)

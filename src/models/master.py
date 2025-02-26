from pathlib import Path
import pycdlib
import logging
import ffmpeg
import hashlib
import shutil
from utils import remove_folder, compute_sha256
from .tracks import Tracks
from .diskimage import DiskImage

class Master:
    """
    Represents the master audiobook collection, managing files and metadata.
    """
    def __init__(self, config, settings):
        self.config = config # config of audio settings
        self.settings = settings # UI and file locations
        self.params = getattr(self.config, "params", {})
        self.input_tracks = None  # Tracks: Raw publisher files Tracks
        self.processed_tracks = None  # Tracks: Encoded and cleaned tracks
        self.master_tracks = None  # Tracks: Loaded from either USB drive or disk image
        self.master_structure = None
        # Direct properties instead of dictionary fields
        self.isbn = settings.get("past_master", {}).get("isbn", "")
        self.sku = settings.get("past_master", {}).get("sku", "")
        self.title = settings.get("past_master", {}).get("title", "")
        self.author = settings.get("past_master", {}).get("author", "")
        self.duration = 0.0
        self.file_count_expected = 0
        self.file_count_observed = 0
        self.status = ""
        self.skip_encoding = False # useful for speeding up debugging
        self.output_path = Path(settings.get("output_folder"))
        self.master_path = self.output_path / self.sku / "master"
        self.processed_path = self.output_path / self.sku / "processed"
        self.image_path =  self.output_path / self.sku / "image"

        self.processed_path.mkdir(parents=True, exist_ok=True)  # Ensure directory exists
        self.image_path.mkdir(parents=True, exist_ok=True)  # Ensure directory exists

        # HEER FOR NOW BUT SHOULD COME FROM CONFIG
        self.output_structure = {
            "tracks_path": "tracks",
            "info_path": "bookInfo",
            "id_file": "bookInfo/id.txt",
            "count_file": "bookInfo/count.txt",
            "metadata_file": ".metadata_never_index",
            "checksum_file": "bookInfo/checksum.txt"
        }
        
        # Logger setup
        self.logger = logging.getLogger(__name__)
    
    @property
    def checksum(self):
        """Computes a SHA-256 checksum for all files in the master directory."""
        if not self.master_structure or not self.master_structure.is_dir():
            self.logger.warning("Master structure is not set or is not a directory.")
            return None
        
        # Collect all files inside the directory recursively
        file_paths = sorted(self.master_structure.rglob("*"))  # Get all files inside the directory
        checksum_value = compute_sha256(file_paths)
        self.logger.info(f"Computed master tracks {file_paths} checksum: {checksum_value}")
        return checksum_value  

    
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
            "skip_encoding": self.skip_encoding
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

    def create(self, input_folder, usb_drive=None):
        logging.info (f"Processed path is {self.processed_path}")
        self.load_input_tracks(input_folder)
        # take input files and process
        self.process_tracks()

         #create structure
        self.create_structure() # do this after process so converted tracks can be put under /tracks

        # Ensure we pass the correct processed tracks directory
        diskimage = DiskImage(output_path=self.image_path)
        image_file = diskimage.create_disk_image(self.master_structure, self.sku)

        self.logger.info(f"Disk image written to {self.image_path}, {image_file}")

        if usb_drive:
            self.logger.info(f"USB drive written to {usb_drive}, {image_file}")
            usb_drive.write_disk_image(image_file)


    def check(self):
        self.logger.info("TODO Check the master")
        self.config.validate_structure(self.master_tracks, self.file_count_observed, self.isbn)    
    
    def load_input_tracks(self, input_folder):
        """Loads the raw input tracks provided by the publisher."""

        self.input_tracks = Tracks(self, input_folder, self.params, ["metadata"])
        
        if Path(self.processed_path).exists() and any(Path(self.processed_path).iterdir()):
            self.processed_tracks = Tracks(self, self.processed_path, self.params, ["metadata"])
            logging.info(f"Attempting to load processed tracks from {self.processed_path}")
            if len(self.processed_tracks.files) != len(self.input_tracks.files):
                logging.warning(f"Processed files unequal in length to input files. Rejecting")
                self.processed_tracks = None
        else:
            self.logger.info(f"No processed files folder found or empty: {self.processed_path}")  
    
    def load_master_from_drive(self, drive_path):
        """Loads a previously created Master from a removable drive."""
        self.logger.info(f"Loading Master from drive: {drive_path}")

        tracks_path = Path(drive_path) / self.config.output_structure["tracks_path"]
        info_path = Path(drive_path) / self.config.output_structure["info_path"]
        
        self.master_tracks = Tracks(tracks_path or image_path, self.params)
        
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
        """Processes tracks and creates a disk image."""
        if not self.input_tracks:
            logging.error("No input tracks provided.")
            raise ValueError("No input tracks provided.")

        if self.skip_encoding and self.processed_tracks:
            logging.info("Skip encoding requested, using processed tracks.")
        elif self.skip_encoding and not self.processed_tracks:
            logging.info("Skip encoding requested, BUT processed tracks not found, encoding anyway")
            self.encode_tracks()
        elif not self.processed_tracks:
            logging.info("No processed tracks found, encoding new files...")
            self.encode_tracks()
        else:
            self.encode_tracks()

    def encode_tracks(self):
        """
        Encodes raw input tracks to a standard format and stores them as processed tracks.
        """
        if not self.input_tracks:
            self.logger.error("No input tracks to encode.")
            raise ValueError("No input tracks to encode.")

        self.logger.info(f"Encoding input tracks...")

        for track in sorted(self.input_tracks.files, key=lambda t: t.file_path.name):
            track.convert(self.processed_path)
            self.logger.info(f"Encoding track: {track.file_path} -> {self.processed_path}")

        self.processed_tracks = Tracks(self, self.processed_path, self.params, ["convert"])

    def create_structure(self):
        """Creates the required directory and file structure for the master."""
        master_path = self.master_path # Use the main output directory
        params = getattr(self.config, "params", {})

        self.master_structure = master_path.resolve()
        self.logger.info(f"Creating master structure in {master_path}")

        # Ensure base master directory is clean
        remove_folder(master_path, self.settings, self.logger)

        # Ensure base master directory exists
        master_path.mkdir(parents=True, exist_ok=True)
        
        # Create required directories and files
        for key, rel_path in self.output_structure.items():
            path = master_path / rel_path
            self.logger.debug(f"Creating structure : {path}")
            if "." not in rel_path:  # If no file extension, assume directory
                path.mkdir(parents=True, exist_ok=True)
            else:  # Otherwise, assume it's a file
                self.logger.debug(f"Creating file : {path}")
                path.touch(exist_ok=True)

        (master_path / self.output_structure["id_file"]).write_text(self.isbn)
        (master_path / self.output_structure["count_file"]).write_text(str(len(self.processed_tracks.files)))
        (master_path / self.output_structure["checksum_file"]).write_text(str(self.checksum))

        self.logger.debug(f"Writing metadata {self.isbn} _ {len(self.processed_tracks.files)} _ {self.checksum}")

        # If processed tracks exist, copy them into `tracks/`
        if self.processed_tracks:
            tracks_path = master_path / self.output_structure["tracks_path"]
            self.logger.info(f"Copying processed tracks to {tracks_path}")

            tracks_path.mkdir(parents=True, exist_ok=True)  # Ensure the folder exists
            for track in self.processed_tracks.files:
                destination = tracks_path / track.file_path.name
                
                # Overwrite file if it exists
                if destination.exists():
                    self.logger.warning(f"Overwriting existing file: {destination}")

                shutil.copy(str(track.file_path), str(destination))
                self.logger.info(f"Copied {track.file_path} -> {destination}")

        else:
            self.logger.error(f"Copying processed tracks to {tracks_path}")
            raise ValueError(f"Missing process_tracks can not proceed")

        self.master_tracks = Tracks(self, tracks_path, params, ["loudness", "silence", "metadata", "frame_errors"])


        self.logger.info("Master structure setup complete.")



    def validate_master(self):
        """Validates an existing Master from drive or disk image."""
        self.logger.info("Validating Master...")
        if self.master_tracks:
            self.logger.info("Checking master with tracks...")
            self._validate_tracks(self.master_tracks)
        elif self.input_tracks:
            self.logger.info("Have input tracks...")

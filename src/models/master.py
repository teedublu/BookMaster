from pathlib import Path
import pycdlib
import logging
import ffmpeg
import hashlib
import shutil
import random
import re
from natsort import natsorted
from utils import remove_folder, compute_sha256
from .tracks import Tracks
from .diskimage import DiskImage
from constants import MAX_DRIVE_SIZE

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
        
        self.usb_drive_tests = settings.get("usb_drive_tests", "").split(",") if settings.get("usb_drive_tests") else []
        self.isbn = settings.get("isbn", "")
        self.sku = settings.get("sku", "")
        self.title = settings.get("title", "")
        self.author = settings.get("author", "")
        self.duration = 0.0
        self.file_count_expected = 0
        self.file_count_observed = 0
        self.status = ""
        self.infer_data = settings.get("infer_data", False)
        self.lookup_csv = settings.get("lookup_csv", False)
        self.skip_encoding = settings.get("skip_encoding", False) # useful for speeding up debugging
        self.output_path = Path(settings.get("output_folder","default_output"))
        self.master_path = self.output_path / self.sku / "master"
        self.processed_path = self.output_path / self.sku / "processed"
        self.image_path =  self.output_path / self.sku / "image"
        self.usb_drive_tests = []
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
        logging.debug(f"Creating new Master {self.isbn},{self.sku} with settings {self.settings} and tests {self.usb_drive_tests}")
        
        # Logger setup
        self.logger = logging.getLogger(__name__)
    
    def __str__(self):
        """
        Returns a string representation of the Master instance, including its tracks,
        structure, and metadata files.
        """
        tracks_info = str(self.master_tracks) if self.master_tracks else "No tracks loaded"
        structure_info = "\n".join(f"{key}: {value}" for key, value in self.output_structure.items())

        # Paths to metadata files
        master_path = self.master_path
        metadata_file = master_path / self.output_structure["metadata_file"]
        count_file = master_path / self.output_structure["count_file"]
        id_file = master_path / self.output_structure["id_file"]
        checksum_file = master_path / "bookInfo/checksum.txt"

        # Check presence of `.metadata_never_index`
        metadata_status = "Present" if metadata_file.exists() else "Not Present"

        # Read values from metadata files (if they exist)
        def read_file(file_path):
            logging.info(file_path)
            return file_path.read_text().strip() if file_path.exists() else "Missing"

        count_value = read_file(count_file)
        id_value = read_file(id_file)
        checksum_value = read_file(checksum_file)

        return (
            f"Master Audiobook Collection:\n"
            f"Title: {self.title}\n"
            f"Author: {self.author}\n"
            f"ISBN: {self.isbn}\n"
            f"SKU: {self.sku}\n"
            f"Duration: {self.duration} seconds\n"
            f"Expected Files: {self.file_count_expected}\n"
            f"Observed Files: {self.file_count_observed}\n"
            f"Status: {self.status}\n"
            f"Encoding Skipped: {self.skip_encoding}\n"
            f"Infer data: {self.infer_data}\n"
            f"\nMaster Structure:\n{structure_info}\n"
            f"\nMetadata Presence:\n"
            f".metadata_never_index: {metadata_status}\n"
            f"bookInfo/count.txt: {count_value}\n"
            f"bookInfo/id.txt: {id_value}\n"
            f"bookInfo/checksum.txt: {checksum_value}\n"
            f"\nTracks:\n{tracks_info}"
        )


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
            "skip_encoding": self.skip_encoding,
            "infer_data": self.infer_data,
            "lookup_csv": self.lookup_csv,
            "usb_drive_tests": self.usb_drive_tests
        }

    @classmethod
    def from_device(cls, config, settings, device_path, tests):
        """ Alternative constructor to initialize Master from a device. """
        instance = cls(config, settings)
        instance.load_master_from_drive(device_path, tests)
        return instance
    
    @classmethod
    def from_img(cls, config, settings, image_path):
        """ Alternative constructor to initialize Master from a disk image using pycdlib. """
        instance = cls(config, settings)
        instance.load_master_from_image(image_path)
        return instance

    def create(self, input_folder, usb_drive=None):
        logging.info (f"Processed path is {self.processed_path} sku is {self.sku}")

        try:
            self.load_input_tracks(input_folder)
        except:
            self.logger.error(f"Failed to load Tracks: {input_folder}")
            return
            

        if not self.sku:
            if self.infer_data:
                self.infer_metadata_from_tracks()
            else:
                self.logger.error(f"Missing ISBN and SKU. {self}")
                return

        # take input files and process
        self.process_tracks()

         #create structure
        self.create_structure() # do this after process so converted tracks can be put under /tracks

        # Ensure we pass the correct processed tracks directory
        diskimage = DiskImage(output_path=self.image_path)
        image_file = diskimage.create_disk_image(self.master_structure, self.sku)

        self.logger.info(f"Disk image written to {self.image_path}, {image_file}")

        if usb_drive:
            self.logger.info(f"Attempting to write {image_file} to USB {usb_drive}")
            usb_drive.write_disk_image(image_file)


    def check(self):
        self.logger.info("TODO Check the master")
        # self.config.validate_structure(self.master_tracks, self.file_count_observed, self.isbn)    
    
    def load_input_tracks(self, input_folder):
        """Loads the raw input tracks provided by the publisher."""
        logging.info(f"Loading input files into Tracks from {input_folder}.")
        try:
            self.input_tracks = Tracks(self, input_folder, self.params, ["metadata","frame_errors"])
        except:
            raise ValueError
            self.logger.error(f"Failed to load Tracks: {input_folder}")
    
    def load_master_from_drive(self, drive_path, tests=None):
        """Loads a previously created Master from a removable drive."""
        tracks_path = Path(drive_path) / self.output_structure["tracks_path"]
        info_path = Path(drive_path) / self.output_structure["info_path"]
        # tests = ["metadata", "frame_errors", "silence"]
        
        self.logger.info(f"Loading Master from drive: {drive_path} _ {tests}")

        self.master_tracks = Tracks(self, tracks_path, self.params, tests)

        isbn_file = Path(drive_path) / self.output_structure["id_file"]
        count_file = Path(drive_path) / self.output_structure["count_file"]
        
        try:
            self.isbn = isbn_file.read_text().strip()
            self.file_count_expected = int(count_file.read_text().strip())
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

        processed_path = self.processed_path
        
        if self.skip_encoding:
            self.processed_tracks = None
            if processed_path.exists() and any(processed_path.iterdir()):
                processed_files = list(processed_path.glob("*.*"))  # Get processed files list
                logging.info(f"Checking processed files in {processed_path}")

                # Compare file count before loading Tracks
                if len(processed_files) != len(self.input_tracks.files):
                    logging.warning("Processed files unequal in length to input files. Rejecting.")
                    self.processed_tracks = None
                else:
                    logging.info("Skip encoding requested, using processed tracks.")
                    self.processed_tracks = Tracks(self, processed_path, self.params, [])
                    return

        remove_folder(processed_path, self.settings, self.logger)
        self.logger.info(f"Processing input tracks into: {processed_path.parent.name}/{processed_path.name}")  
        self.encode_tracks()

    def encode_tracks(self):
        """
        Encodes raw input tracks to a standard format and stores them as processed tracks.
        """
        if not self.input_tracks:
            self.logger.error("No input tracks to encode.")
            raise ValueError("No input tracks to encode.")

        bit_rate = self.calculate_encoding_for_1gb()

        for track in natsorted(self.input_tracks.files, key=lambda t: t.file_path.name):
            track.convert(self.processed_path, bit_rate)
            self.logger.info(f"Encoding track: {track.file_path.parent.name}/{track.file_path.name} and moving to -> {self.processed_path}")

        self.processed_tracks = Tracks(self, self.processed_path, self.params, ["metadata"]) #metadata required to get duration
        self.logger.info(f"Processed Tracks total size {self.processed_tracks.total_size}")

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
            self.logger.error(f"Missing process_tracks can not proceed ")
            raise ValueError(f"Missing process_tracks can not proceed")
            return

        self.master_tracks = Tracks(self, tracks_path, params, [])


        self.logger.info("Master structure setup complete.")

    def calculate_encoding_for_1gb(self):
        """
        Determines if the total size of the tracks fits on a 1GB drive.
        If not, calculates the required encoding bitrate to make it fit.
        
        Returns:
            int: The selected bitrate in .
        """

        current_size_bytes = self.input_tracks.total_size_after_encoding  # Total encoded size
        current_bit_rate = int(self.config.params["encoding"]["bit_rate"])  # e.g., 192 for 192

        if current_size_bytes <= MAX_DRIVE_SIZE:
            self.logger.info(f"Tracks fit within 1GB ({current_size_bytes / (1024**2):.2f} MB). No encoding changes required.")
            return current_bit_rate

        # Calculate required bitrate to fit within 1GB
        reduction_factor = MAX_DRIVE_SIZE / current_size_bytes
        required_bit_rate = int(current_bit_rate * reduction_factor)

        # Ensure bitrate remains in a reasonable range (e.g., 32000 - 192000)
        MIN_BITRATE = 32
        MAX_BITRATE = current_bit_rate  # Keep within original bitrate
        adjusted_bit_rate = max(MIN_BITRATE, min(required_bit_rate, MAX_BITRATE))

        if adjusted_bit_rate == current_bit_rate:
            self.logger.warning(
                f"Tracks exceed 1GB ({current_size_bytes / (1024**2):.2f} MB), "
                f"but reducing bitrate further may cause quality loss."
            )
        
        else:
            self.logger.warning(
                f"Tracks exceed 1GB ({current_size_bytes / (1024**2):.2f} MB). "
                f"Reducing bitrate from {current_bit_rate} to {adjusted_bit_rate}."
            )

        return adjusted_bit_rate

    def validate_master(self):
        """Validates an existing Master from drive or disk image."""
        self.logger.info("Validating Master...")
        if self.master_tracks:
            self.logger.info("Checking master with tracks...")
            self._validate_tracks(self.master_tracks)
        elif self.input_tracks:
            self.logger.info("Have input tracks...")

    def infer_metadata_from_tracks(self):
        """Derives title, author, and SKU from the first Track's metadata if not already set."""
        self.logger.info("Inferring data from metadata.")

        if not self.input_tracks or not self.input_tracks.files:
            self.logger.warning("No tracks available to infer metadata.")
            return

        # Get metadata from the first track
        first_track = self.input_tracks.files[0]
        metadata_tags = first_track.metadata.get("tags", {})

        # Infer title
        if not self.title and "title" in metadata_tags:
            self.title = metadata_tags["title"].strip()
            self.logger.info(f"Inferred title: {self.title}")

        # Infer author
        if not self.author:
            # Prefer "artist" tag, fallback to "album_artist"
            self.author = metadata_tags.get("artist") or metadata_tags.get("album_artist")
            if self.author:
                self.author = self.author.strip()
                self.logger.info(f"Inferred author: {self.author}")

        # Generate SKU if not set
        if not self.sku:
            self.sku = self.generate_sku()
            self.logger.info(f"Generated SKU: {self.sku}")

    def generate_sku(self):
        """Generates SKU in the format BK-XXXXX-ABCD where AB is from author, CD from title."""
        if not self.isbn:
            self.isbn = str(random.randint(10000, 99999))
        
        # Extract author initials (AB)
        author_abbr = "XX"
        if self.author:
            author_parts = self.author.split()
            if len(author_parts) > 1:
                author_abbr = author_parts[-1][:2].upper()  # Last name first two letters
            else:
                author_abbr = author_parts[0][:2].upper()  # Only one name

        # Extract title initials (CD)
        title_abbr = "YY"
        if self.title:
            words = re.findall(r"\b\w", self.title)  # Get first letter of each word
            if len(words) >= 2:
                title_abbr = (words[0] + words[1]).upper()  # First two letters from title
            elif words:
                title_abbr = (words[0] + "X").upper()  # Only one word, pad with X


        return f"BK-{self.isbn}-{author_abbr}{title_abbr}"


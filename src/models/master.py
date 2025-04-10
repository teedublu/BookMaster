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
from .diskimage import DiskImage
from constants import MAX_DRIVE_SIZE

class Master:
    """
    Represents the master audiobook collection, managing files and metadata.
    """
    def __init__(self, config, settings, master_path=None, expected_count=None):
        self.config = config # config of audio settings
        self.settings = settings # UI and file locations
        self.params = getattr(self.config, "params", {})
        self.output_path = Path(settings.get("output_folder","default_output"))
        self.input_tracks = None  # Tracks: Raw publisher files Tracks
        self.processed_tracks = None  # Tracks: Encoded and cleaned tracks
        self.master_tracks = None  # Tracks: Loaded from either USB drive or disk image
        self.master_structure = None
        self.usb_drive_tests = settings.get("usb_drive_tests", "").split(",") if settings.get("usb_drive_tests") else []
        self.isbn = settings.get("isbn", "")
        self.sku = settings.get("sku", "")
        self.title = settings.get("title", "")
        self.author = settings.get("author", "")
        self.infer_data = settings.get("infer_data", False)

        self.master_path = Path(master_path) if master_path else self.output_path / self.sku / "master"
        self.master_path.mkdir(parents=True, exist_ok=True) 

        self.file_count_expected = expected_count if expected_count else 0
        self._file_count_observed = 0

        self._author = None
        self._title = None
        self._isbn = None
        self.status = ""
        
        # self.lookup_csv = settings.get("lookup_csv", False)
        self.skip_encoding = settings.get("skip_encoding", False) # useful for speeding up debugging
        
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
        input_tracks_info = str(self.input_tracks) if self.input_tracks else None
        processed_tracks_info = str(self.processed_tracks) if self.processed_tracks else None
        master_tracks_info = str(self.master_tracks) if self.master_tracks else None

        tracks_info = input_tracks_info or processed_tracks_info or master_tracks_info or None


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
            f"\nInput Tracks:\n{input_tracks_info}"
            f"\nProcessed Tracks:\n{processed_tracks_info}"
            f"\nMaster Tracks:\n{master_tracks_info}"
        )

    
    @property
    def duration(self):
        return self.master_tracks.duration if self.master_tracks else 0

    @property
    def author(self):
        return self.master_tracks.author if self.master_tracks else 'Unknown'

    @author.setter
    def author(self, value):
        # should only be used inbound after which tracks will define the author
        self._author = value;

    @property
    def title(self):
        return self.master_tracks.title if self.master_tracks else 'Unknown'

    @title.setter
    def title(self, value):
        # should only be used inbound after which tracks will define the author
        self._title = value;

    @property
    def checksum_expected(self):
        """Returns the checksum stored in bookInfo/checksum.txt, or None if missing."""
        checksum_file = self.master_path / "bookInfo" / "checksum.txt"
        if checksum_file.exists():
            try:
                return checksum_file.read_text(encoding="utf-8").strip()
            except Exception as e:
                self.logger.warning(f"Could not read expected checksum: {e}")
        return None

    @property
    def checksum_actual(self):
        """Computes a SHA-256 checksum of the Master files."""
        try:
            all_files = [p for p in self.master_path.rglob("*") if p.is_file()]
            return compute_sha256(all_files)
        except Exception as e:
            self.logger.warning(f"Could not compute actual checksum: {e}")
            return None


    @property
    def processed_path(self):
        processed_path = self.output_path / self.sku / "processed"
        processed_path.mkdir(parents=True, exist_ok=True) 
        return processed_path

    @property
    def image_path(self):
        image_path = self.output_path / self.sku / "image"
        image_path.mkdir(parents=True, exist_ok=True) 
        return image_path

    @property
    def file_count_observed(self):
        """Returns the number of files in Tracks, or 0 if Tracks is None."""
        return len(self.master_tracks.files) if getattr(self, "master_tracks", None) and hasattr(self.master_tracks, "files") else 0
    


    @property
    def checksum(self):
        """Computes a SHA-256 checksum for all files in the master directory."""
        if not self.master_structure or not self.master_structure.is_dir():
            self.logger.warning("Master structure is not set or is not a directory.")
            return None
        
        # Collect all files inside the directory recursively
        file_paths = natsorted(self.master_structure.rglob("*"))  # Get all files inside the directory
        checksum_value = compute_sha256(file_paths)
        self.logger.info(f"Computed master_structure checksum: {checksum_value}")
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
            # "lookup_csv": self.lookup_csv, # this should not be passed UI specific only
            "usb_drive_tests": self.usb_drive_tests
        }

    @classmethod
    def from_device(cls, config, settings, device_path, tests):
        """ Alternative constructor to initialize Master from a device. """
        instance = cls(config, settings, master_path=device_path)
        instance.load_master_from_drive(tests)
        return instance
    
    @classmethod
    def from_img(cls, config, settings, image_path):
        """ Alternative constructor to initialize Master from a disk image using pycdlib. """
        instance = cls(config, settings)
        instance.load_master_from_image(image_path)
        return instance

    def create(self, input_folder, usb_drive=None):

        logging.info (f"Creating master with isbn {self.isbn} sku {self.sku}")
        self.load_input_tracks(input_folder)
        # take input files and process
        self.process_tracks()
         #create structure
        self.create_master_structure() # do this after process so converted tracks can be put under /tracks

        # Ensure we pass the correct processed tracks directory
        diskimage = DiskImage(output_path=self.image_path)
        image_file = diskimage.create_disk_image(self.master_structure, self.sku)

        self.logger.info(f"Disk image written to {self.image_path}, {image_file}")

        if usb_drive:
            self.logger.info(f"Attempting to write {image_file} to USB {usb_drive}")
            usb_drive.write_disk_image(image_file) 
    
    def load_input_tracks(self, input_folder):
        """Loads the raw input tracks provided by the publisher."""
        self.input_tracks = Tracks(self, input_folder, self.params, ["frame_errors"])
    
    def load_master_from_drive(self, tests=None):
        drive_path = self.master_path
        """Loads a previously created Master from a removable drive."""
        tracks_path = Path(drive_path) / self.output_structure["tracks_path"]
        info_path = Path(drive_path) / self.output_structure["info_path"]
        # tests = ["metadata", "frame_errors", "silence"]
        
        self.logger.info(f"Loading Master from drive: {drive_path} _ {tests}")

        self.master_tracks = Tracks(self, tracks_path, self.params, tests)

        try:
            isbn_file = Path(drive_path) / self.output_structure["id_file"]
            count_file = Path(drive_path) / self.output_structure["count_file"]
            isbn = str(isbn_file.read_text().strip())
            count = int(count_file.read_text().strip())
            self.file_count_expected = count
        except FileNotFoundError:
            self.logger.error("Required metadata files (id.txt, count.txt) missing in bookInfo.")
            raise
        
        self.logger.debug(f"Loaded Master with count={self.file_count_observed} isbn={self.isbn} author={self.author} duration={self.duration}")
        
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
            logging.debug("Skip encoding requested, finding processed path.")
            self.processed_tracks = None
            if processed_path.exists() and any(processed_path.iterdir()):
                processed_files = list(processed_path.glob("*.*"))  # Get processed files list
                logging.info(f"Checking processed files in {processed_path}")

                # Compare file count before loading Tracks
                if len(processed_files) != len(self.input_tracks.files):
                    logging.warning(f"Processed files ({len(processed_files)}) unequal in length to input files({len(self.input_tracks.files)}). Rejecting.")
                    self.processed_tracks = None
                else:
                    self.processed_tracks = Tracks(self, processed_path, self.params, [])
                    logging.debug("Found processed path, created Tracks from processed files.")
                    return

        # if get here then zap anything in processed path and start encoding again
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
            self.logger.info(f"Encoding track: {track.file_path.parent.name}/{track.file_path.name} and moving to -> {self.processed_path.name}")

        self.processed_tracks = Tracks(self, self.processed_path, self.params, ["metadata"]) #metadata required to get duration
        self.logger.info(f"Processed Tracks total size {self.processed_tracks.total_size}")

    def create_master_structure(self):
        """Creates the required directory and file structure for the master."""

        if not self.processed_tracks:
            self.logger.error(f"Missing process_tracks can not proceed ")
            raise ValueError(f"Missing process_tracks can not proceed")
            return

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

        self.logger.debug(f"Writing data to files id->{self.isbn} count->{len(self.processed_tracks.files)} checksum->{self.checksum}")

        # If processed tracks exist, copy them into `tracks/`
        tracks_path = master_path / self.output_structure["tracks_path"]
        self.logger.info(f"Copying processed tracks to {tracks_path.parent.name}/{tracks_path.name}")

        tracks_path.mkdir(parents=True, exist_ok=True)  # Ensure the folder exists
        for processed_track in self.processed_tracks.files:
            shutil.copy(str(processed_track.file_path), str(tracks_path))
            self.logger.info(f"Copied {processed_track.file_path.name} from /{processed_track.file_path.parent.name} -> /{tracks_path.parent.name}/{tracks_path.name}")
            
        self.master_tracks = Tracks(self, tracks_path, params, [])


        self.logger.info("Master structure setup complete.")

    def calculate_encoding_for_1gb(self):
        """Determines if the total size of the tracks fits on a 1GB drive.
        If not, calculates the required encoding bitrate to make it fit. 
        """

        current_size_bytes = self.input_tracks.total_size_after_encoding  # Total encoded size
        current_bit_rate = int(self.config.params["encoding"]["bit_rate"])  # e.g., 192 for 192

        if current_size_bytes <= MAX_DRIVE_SIZE:
            self.logger.info(f"Tracks fit within 1GB {current_size_bytes} ({current_size_bytes / (1024**2):.2f} MB). No encoding changes required.")
            return current_bit_rate

        # Calculate required bitrate to fit within 1GB
        reduction_factor = MAX_DRIVE_SIZE / current_size_bytes
        required_bit_rate = int(current_bit_rate * reduction_factor)

        # Ensure bitrate remains in a reasonable range (e.g., 32000 - 192000)
        MIN_BITRATE = 32
        MAX_BITRATE = current_bit_rate  # Keep within original bitrate
        adjusted_bit_rate = max(MIN_BITRATE, min(required_bit_rate, MAX_BITRATE))

        if adjusted_bit_rate == current_bit_rate:
            self.logger.warning(f"Tracks exceed 1GB ({current_size_bytes / (1024**2):.2f} MB), but reducing bitrate further may cause quality loss.")
        
        else:
            self.logger.warning(f"Tracks exceed 1GB ({current_size_bytes / (1024**2):.2f} MB). Reducing bitrate from {current_bit_rate} to {adjusted_bit_rate}.")

        return adjusted_bit_rate

    def validate(self):
        #check file count
        #check silences
        #encoding
        #checksum
        #speed

        """Validates an existing Master from drive or disk image."""
        self.logger.info("Validating Master...")
        if not self.master_tracks:
            self.logger.info("No master tracks found...")
            return False
        
        if self.file_count_expected != self.file_count_observed:
            self.logger.info("Expected and observed file count mismatch.")
            return False
        
        if not self.master_tracks.all_valid:
            self.logger.info(f"Some invalid tracks found: {self.master_tracks.invalid_tracks}")

        return True

    def infer_metadata_from_tracks(self, input_folder):
        """Derives title, author, and SKU from the first Track's metadata if not already set."""
        self.logger.info("Inferring Master data from metadata.")

        if not input_folder:
            self.logger.warning("No tracks available to infer metadata.")
            return

        # Get metadata from the first track
        first_track = self.input_tracks.files[0]
        metadata_tags = first_track.metadata.get("tags", {})

        # Infer title (Track will have already cleaned album/title/name into a Track.title)
        if not self.title and "title" in metadata_tags:
            self.title = metadata_tags["title"].strip()
            self.logger.info(f"Inferred title: {self.title} in {metadata_tags}")

        # Infer author
        # This should be handled by the individual tracks rather than here. Allow getter of author to delegate to Tracks>Track
        # if not self.author:
        #     # Prefer "artist" tag, fallback to "album_artist"
        #     self.author = metadata_tags.get("artist") or metadata_tags.get("album_artist")
        #     if self.author:
        #         self.author = self.author.strip()
        #         self.logger.info(f"Inferred author: {self.author}")

        # Generate SKU if not set
        if not self.sku:
            self.sku = self.generate_sku()
            self.logger.info(f"Generated SKU: {self.sku}")

    def lookup_isbnOLD(self, new_isbn):
        
        """Triggered when ISBN changes. Looks up book details if ISBN is 13 digits."""
        if len(new_isbn) != 13 :
            logging.debug(f"Invalid ISBN {new_isbn} len={len(new_isbn)}")
            return

        logging.info(f"Master looking up data for {new_isbn}")

        row = self.config.books.get(new_isbn, {})  # Fast lookup from cached dictionary

        if not row:
            logging.warning(f"No data found for {new_isbn}")
            return

        logging.debug(f"Data found for {new_isbn} {row}")

        self.sku = row.get('SKU', "")
        self.title = row.get('Title', "")
        self.author = row.get('Author', "")
        self.file_count_expected = row.get('ExpectedFileCount', 0)
        self.duration = parse_time_to_minutes(row.get('Duration'))


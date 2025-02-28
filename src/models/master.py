from pathlib import Path
import pycdlib
import logging
import ffmpeg
import hashlib
import shutil
from natsort import natsorted
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
            "skip_encoding": self.skip_encoding
        }

    @classmethod
    def from_device(cls, config, settings, device_path):
        """ Alternative constructor to initialize Master from a device. """
        instance = cls(config, settings)
        instance.load_master_from_drive(device_path)
        return instance
    
    @classmethod
    def from_img(cls, config, settings, image_path):
        """ Alternative constructor to initialize Master from a disk image using pycdlib. """
        instance = cls(config, settings)
        instance.load_master_from_image(image_path)
        return instance

    def create(self, input_folder, usb_drive=None):
        logging.info (f"Processed path is {self.processed_path}")
        self.load_input_tracks(input_folder)

        # will it fit
        # calculate_encoding_for_1gb
        # will have to do the conversion first? otherwise need to look at each file and see what it would be after eoncding and see??

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
        logging.info(f"Loading input files into Tracks from {input_folder}.")
        self.input_tracks = Tracks(self, input_folder, self.params, ["metadata","frame_errors"])

    
    def load_master_from_drive(self, drive_path):
        """Loads a previously created Master from a removable drive."""
        

        tracks_path = Path(drive_path) / self.output_structure["tracks_path"]
        info_path = Path(drive_path) / self.output_structure["info_path"]
        tests = ["metadata", "frame_errors", "silence"]
        
        self.logger.info(f"Loading Master from drive: {drive_path} _ {tracks_path} _ {info_path}")

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

        for track in natsorted(self.input_tracks.files, key=lambda t: t.file_path.name):
            track.convert(self.processed_path)
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
        If not, calculates the required encoding settings to make it fit.
        """
        ONE_GB_KB = 1_000_000  # 1GB in KB
        current_size_kb = self.tracks.total_size // 1024  # Convert bytes to KB

        if current_size_kb <= ONE_GB_KB:
            self.logger.info(f"Tracks fit within 1GB ({current_size_kb} KB). No encoding changes required.")
            return self.config.params["encoding"]["bit_rate"]  # Keep existing encoding

        # Calculate required bitrate to fit within 1GB
        reduction_factor = ONE_GB_KB / current_size_kb
        current_bitrate_kbps = self.config.params["encoding"]["bit_rate"]  # e.g., 192 for 192kbps
        required_bitrate_kbps = int(current_bitrate_kbps * reduction_factor)

        # Ensure bitrate remains in a reasonable range (e.g., 32kbps - 192kbps)
        MIN_BITRATE = 32
        MAX_BITRATE = current_bitrate_kbps
        adjusted_bitrate_kbps = max(MIN_BITRATE, min(required_bitrate_kbps, MAX_BITRATE))

        self.logger.warning(
            f"Tracks exceed 1GB ({current_size_kb} KB). "
            f"Reducing bitrate from {current_bitrate_kbps}kbps to {adjusted_bitrate_kbps}kbps."
        )

        return adjusted_bitrate_kbps



    def validate_master(self):
        """Validates an existing Master from drive or disk image."""
        self.logger.info("Validating Master...")
        if self.master_tracks:
            self.logger.info("Checking master with tracks...")
            self._validate_tracks(self.master_tracks)
        elif self.input_tracks:
            self.logger.info("Have input tracks...")

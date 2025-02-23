from pathlib import Path
import pycdlib
import logging
import ffmpeg
import hashlib
import shutil
from .tracks import Tracks
from .diskimage import DiskImage

class Master:
    """
    Represents the master audiobook collection, managing files and metadata.
    """
    def __init__(self, config, settings):
        self.config = config # config of audio settings
        self.settings = settings # UI and file locations
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

        # HEER FOR NOW BUT SHOULD COME FROM CONFIG
        self.output_structure = {
            "tracks_path": "tracks",
            "info_path": "bookInfo",
            "id_file": "bookInfo/id.txt",
            "count_file": "bookInfo/count.txt",
            "metadata_file": ".metadata_never_index"
        }
        
        # Logger setup
        self.logger = logging.getLogger(__name__)
    
    @property
    def checksum(self):
        """Computes a SHA-256 checksum for all files in master_structure."""
        if not self.master_structure:
            self.logger.warning("No master tracks found, cannot compute checksum.")
            return None

        hasher = hashlib.sha256()
        file_paths = sorted(track.file_path for track in self.master_structure)  # Sort for consistency

        for file_path in file_paths:
            try:
                with open(file_path, "rb") as f:
                    while chunk := f.read(8192):  # Read file in chunks
                        hasher.update(chunk)
            except Exception as e:
                self.logger.error(f"Failed to compute checksum for {file_path}: {e}")
                return None

        checksum_value = hasher.hexdigest()
        self.logger.info(f"Computed master tracks checksum: {checksum_value}")
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

    def create(self):
       
        # take input files and process
        self.process_tracks()

         #create structure
        self.create_structure() # do this after process so converted tracks can be put under /tracks

        # Ensure we pass the correct processed tracks directory
        diskimage = DiskImage(output_base=self.settings.get("output_folder"))
        diskimage.create_disk_image(self.master_structure, self.sku)


    def check(self):
        self.logger.info("TODO Check the master")
        self.config.validate_structure(self.master_tracks, self.file_count_observed, self.isbn)    
    
    def load_input_tracks(self, input_folder):
        """Loads the raw input tracks provided by the publisher."""
        self.logger.info(f"Loading Master input tracks {input_folder}")
        self.input_tracks = Tracks(input_folder, getattr(self.config, "params", {}))

    def encode_tracks(self):
        """
        Encodes raw input tracks to a standard format and stores them as processed tracks.
        """
        if not self.input_tracks:
            self.logger.error("No input tracks to encode.")
            raise ValueError("No input tracks to encode.")

        processed_folder = Path(self.settings.get("processed_folder"))
        processed_folder.mkdir(parents=True, exist_ok=True)  # Ensure directory exists

        self.logger.info(f"Encoding input tracks...")

        for track in self.input_tracks.files:
            input_file = track.file_path
            output_file = processed_folder / f"{track.file_path.stem}_processed.mp3"

            self.logger.info(f"Encoding track: {input_file} -> {output_file}")

            try:
                # Convert to MP3 format with standard bitrate and sampling rate
                (
                    ffmpeg.input(str(input_file))
                    .output(str(output_file), audio_bitrate="192k", ar="44100", ac="2", format="mp3")
                    .run(overwrite_output=True, capture_stderr=True)
                )

                self.logger.info(f"Successfully encoded: {output_file}")

            except ffmpeg.Error as e:
                self.logger.error(f"Encoding failed for {input_file}: {e}")

        # Reload processed tracks after encoding
        self.processed_tracks = Tracks(processed_folder, self.config)


    def _load_processed_tracks(self):
        """Loads previously encoded and cleaned tracks to avoid re-encoding."""
        processed_folder = self.settings.get("processed_folder")
        logging.info(f"Load processed tracks from {processed_folder}")
        if Path(processed_folder).exists():
            self.processed_tracks = Tracks(processed_folder, self.config)
        else:
            self.logger.info(f"No processed files found in settings: {self.settings}")  
    
    def load_master_from_drive(self, drive_path):
        """Loads a previously created Master from a removable drive."""
        self.logger.info(f"Loading Master from drive: {drive_path}")
        tracks_path = Path(drive_path) / self.config.output_structure["tracks_path"]
        info_path = Path(drive_path) / self.config.output_structure["info_path"]
        
        self.master_tracks = Tracks(tracks_path or image_path, self.config)
        
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

        if not self.processed_tracks:
            logging.info("No processed tracks found, encoding new files...")
            self.encode_tracks()
        else:
            logging.info(f"Using previously processed tracks {self.processed_tracks.directory}, skipping re-encoding.")

        # Debugging: Print the actual processed directory
        logging.debug(f"Processed tracks directory AFTER assignment: {self.processed_tracks.directory}")


    def create_structure(self):
        """Creates the required directory and file structure for the master."""
        master_path = Path(self.settings.get("output_folder")) / self.sku # Use the main output directory
        self.master_structure = master_path.resolve()
        self.logger.info(f"Creating master structure in {master_path}")

        # Ensure base master directory exists
        master_path.mkdir(parents=True, exist_ok=True)

        # Create required directories and files
        for key, rel_path in self.output_structure.items():
            path = master_path / rel_path
            if "." not in rel_path:  # If no file extension, assume directory
                path.mkdir(parents=True, exist_ok=True)
            else:  # Otherwise, assume it's a file
                path.touch(exist_ok=True)

        # TODO the files need to have ISBN and count inserted!!!
        # TODO the files need to have ISBN and count inserted!!!
        # TODO the files need to have ISBN and count inserted!!!
        # TODO the files need to have ISBN and count inserted!!!
        

        # If processed tracks exist, move them into `tracks/`
        if self.processed_tracks:
            tracks_path = master_path / self.output_structure["tracks_path"]
            self.logger.info(f"Moving processed tracks to {tracks_path}")

            tracks_path.mkdir(parents=True, exist_ok=True)  # Ensure the folder exists
            for track in self.processed_tracks.files:
                destination = tracks_path / track.file_path.name
                
                # Overwrite file if it exists
                if destination.exists():
                    self.logger.warning(f"Overwriting existing file: {destination}")

                shutil.move(str(track.file_path), str(destination))
                self.logger.info(f"Moved {track.file_path} -> {destination}")

        self.master_tracks = Tracks(tracks_path, self.config)


        self.logger.info("Master structure setup complete.")



    def validate_master(self):
        """Validates an existing Master from drive or disk image."""
        self.logger.info("Validating Master...")
        if self.master_tracks:
            self.logger.info("Checking master with tracks...")
            self._validate_tracks(self.master_tracks)
        elif self.input_tracks:
            self.logger.info("Have input tracks...")

    


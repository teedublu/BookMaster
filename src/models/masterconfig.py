import json
import os
from pathlib import Path

class MasterConfig:
    """
    Handles settings and configuration parameters for master creation.
    """
    def __init__(self, settings, config):
        self.config = config or "config.json"
        self.output_folder = Path("./output")
        self.file_naming_convention = "{track_number:02d}_{title}.{ext}"
        self.input_formats = ["mp3", "wav"]
        self.output_format = {
            "format": "mp3",
            "bit_rate": "96000",
            "sample_rate": 44100,
            "channels": 2,
            "loudness": -14
        }
        self.output_structure = {
            "tracks_path": "tracks",
            "info_path": "bookInfo",
            "id_file": "bookInfo/id.txt",
            "count_file": "bookInfo/count.txt",
            "metadata_file": ".metadata_never_index"
        }



    def process_tracks(self):
        """Processes tracks and creates a disk image."""
        if not self.input_tracks:
            logging.error("No input tracks provided.")
            raise ValueError("No input tracks provided.")

        if not self.processed_tracks:
            logging.info("No processed tracks found, encoding new files...")
            self._encode_tracks()
        else:
            logging.info(f"Using previously processed tracks {self.processed_tracks.directory}, skipping re-encoding.")

        # Debugging: Print the actual processed directory
        logging.debug(f"Processed tracks directory AFTER assignment: {self.processed_tracks.directory}")


        # Ensure the path is absolute before passing
        processed_path = str(Path(self.processed_tracks.directory).resolve())
        logging.debug(f"Resolved processed path: {processed_path}")

        # Ensure we pass the correct processed tracks directory
        diskimage = DiskImage(output_base=self.settings.get("output_folder"))
        diskimage.create_disk_image(processed_path, self.sku)

    

    def validate_structure(self, root, file_count_observed, isbn):
        """ Checks if the required directory and file structure exists and validates contents. """
        missing = []
        for key, rel_path in self.output_structure.items():
            path = root / rel_path
            if not path.exists():
                missing.append(key)
        
        if missing:
            raise ValueError(f"Missing required structure components: {missing}")
        
        count_file = root / self.output_structure["count_file"]
        if count_file.exists():
            with open(count_file, "r") as f:
                try:
                    expected_count = int(f.read().strip())
                    if file_count_observed != expected_count:
                        raise ValueError(f"Mismatch in file count: expected {expected_count}, found {file_count_observed}")
                except ValueError:
                    raise ValueError("Invalid data in count.txt, unable to verify file count.")
        
        id_file = root / self.output_structure["id_file"]
        if id_file.exists():
            with open(id_file, "r") as f:
                id_value = f.read().strip()
                if not id_value:
                    raise ValueError("id.txt is empty, unable to verify ID.")
        
        if isbn is None:
            raise ValueError("ISBN is not set, unable to verify structure.")
    
    def _load_settings(self):
        """ Reads settings from a file. """
        if os.path.exists(self.config):
            with open(self.config, "r") as f:
                data = json.load(f)
                self.__dict__.update(data)

    def _save_settings(self):
        """ Saves settings to a file. """
        with open(self.config, "w") as f:
            json.dump(self.__dict__, f, indent=4)

    def _validate_config(self):
        """ Ensures all required configuration values are present and valid. """
        required_keys = ["output_folder", "file_naming_convention", "input_formats", "output_format", "output_structure"]
        for key in required_keys:
            if not hasattr(self, key):
                raise ValueError(f"Missing required configuration key: {key}")
        
        if not isinstance(self.input_formats, list) or not self.input_formats:
            raise ValueError("input_formats must be a non-empty list.")
        
        if not isinstance(self.output_format, dict) or "format" not in self.output_format:
            raise ValueError("output_format must be a dictionary containing at least a 'format' key.")

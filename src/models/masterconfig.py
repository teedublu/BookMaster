import json
import os
from pathlib import Path

class MasterConfig:
    """
    Handles settings and configuration parameters for master creation.
    """
    def __init__(self, settings_file=None):
        self.settings_file = settings_file or "config.json"
        self.output_folder = Path("./output")
        self.file_naming_convention = "{track_number:02d}_{title}.{ext}"
        self.input_formats = ["mp3", "wav"]
        self.output_format = {
            "format": "mp3",
            "bit_rate": "192k",
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

    def create_structure(self, root):
        """ Creates the required directory and file structure for the master. """
        for key, rel_path in self.output_structure.items():
            path = root / rel_path
            if path.suffix == "":  # Directories
                path.mkdir(parents=True, exist_ok=True)
            else:  # Files
                path.touch(exist_ok=True)

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
        if os.path.exists(self.settings_file):
            with open(self.settings_file, "r") as f:
                data = json.load(f)
                self.__dict__.update(data)

    def _save_settings(self):
        """ Saves settings to a file. """
        with open(self.settings_file, "w") as f:
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

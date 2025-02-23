import json
import logging
from pathlib import Path

class Config:
    """Handles shared Master processing configuration (Read-Only)."""

    def __init__(self):
        # Get the directory where config.py is located
        self.config_dir = Path(__file__).parent
        self.config_file = self.config_dir / "config.json"

        # Set default folders to ~/BookMaster/
        self.default_base_dir = Path.home() / "BookMaster"

        # Default configuration
        self.default_config = {
            "encoding": {
                "bitrate": "192k",
                "sample_rate": 44100,
                "channels": 2
            }
        }

        self.config = self.load_config()

    def load_config(self):
        """Loads the config.json file from the same folder as this script."""
        if not self.config_file.exists():
            logging.warning(f"Config file not found: {self.config_file}, using defaults.")
            return self.default_config

        try:
            with open(self.config_file, 'r') as file:
                loaded_config = json.load(file)

            # Ensure missing keys are filled with defaults
            merged_config = {**self.default_config, **loaded_config}
            return merged_config

        except json.JSONDecodeError as e:
            logging.error(f"Error parsing config file {self.config_file}: {e}")
            return self.default_config

import json
import csv
import sys
import logging
from pathlib import Path

COLORS = {
    "green": "\033[92m",
    "yellow": "\033[93m",
    "red": "\033[91m",
    "reset": "\033[0m"
}

# Disable colors if output is not a terminal (e.g., piped to a file)
if not sys.stdout.isatty():
    COLORS = {key: "" for key in COLORS}


class Config:
    """Handles shared Master processing configuration (Read-Only)."""

    def __init__(self):
        # Get the directory where config.py is located
        self.config_dir = Path(__file__).parent
        self.config_file = self.config_dir / "config.json"
        self.books_csv_path = self.config_dir / "books.csv"  # Full path to books.csv
        self.books = self._load_books_csv()

        # Set default folders to ~/BookMaster/
        self.default_base_dir = Path.home() / "BookMaster"

        # Default configuration
        self.default_config = {
            "encoding": {
                "bit_rate": "96000",
                "sample_rate": 44100,
                "channels": 1
            }
        }

        self.params = self.load_config()

    def __str__(self):
        return json.dumps({
            "config_dir": str(self.config_dir),
            "config_file": str(self.config_file),
            "books_csv_path": str(self.books_csv_path),
            "default_base_dir": str(self.default_base_dir),
            "default_config": str(self.default_config)
        }, indent=2)

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
            logging.debug(f"Using config {merged_config}")
            return merged_config

        except json.JSONDecodeError as e:
            logging.error(f"Error parsing config file {self.config_file}: {e}")
            return self.default_config

    def _load_books_csv(self):
        """Loads books.csv into memory as a dictionary for quick lookup."""
        books = {}
        try:
            with self.books_csv_path.open("r", encoding="utf-8") as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    isbn = row.get("ISBN")
                    if isbn:
                        books[isbn] = row  # Store row with ISBN as key
            logging.info("Loaded books.csv into memory.")
        except FileNotFoundError:
            logging.error(f"Error: {self.books_csv_path} not found.")
        except Exception as e:
            logging.error(f"Error reading {self.books_csv_path}: {e}")
        return books  # Return empty dict if file is missing
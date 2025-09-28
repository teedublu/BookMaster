import json
import logging
from pathlib import Path
import platformdirs  # For user-specific config storage

# Define per-user settings directory
SETTINGS_DIR = Path(platformdirs.user_config_dir("VoxblockMaster"))
SETTINGS_DIR.mkdir(parents=True, exist_ok=True)  # Ensure directory exists

# Define settings file path
SETTINGS_FILE = SETTINGS_DIR / "settings.json"

# Default UI settings
DEFAULT_SETTINGS = {
    "use_webcam": False,
    "input_folder": str(Path.home() / "Documents/VoxblockMaster"),
    "output_folder": str(Path.home() / "Documents/VoxblockMaster/output"),
    "isbn": "",
    "manual_data": False,
    "lookup_csv": False,
    "find_isbn_folder": False,
    "skip_encoding": False,
    "skip_image_creation": False,
    "write_image_mode": False,
    "usb_drive_check_on_mount": False
}

def load_settings():
    """Loads per-user UI settings from JSON file."""
    if not SETTINGS_FILE.exists():
        logging.warning(f"{SETTINGS_FILE} not found. Creating a default settings file.")
        save_settings(DEFAULT_SETTINGS)

    try:
        with open(SETTINGS_FILE, 'r') as file:
            settings = json.load(file)
            logging.info(f"Loading settings: {settings}")
            return settings
    except (json.JSONDecodeError, KeyError) as e:
        logging.error(f"Error loading settings in {file}: {e}")
        return DEFAULT_SETTINGS

def save_settings(settings):
    """Saves per-user UI settings."""
    
    with open(SETTINGS_FILE, 'w') as file:
        json.dump(settings, file, indent=4)
    logging.info(f"Settings saved to {SETTINGS_FILE} : {settings}")

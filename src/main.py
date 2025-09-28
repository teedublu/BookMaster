"""
Main entry point for the application.
Initializes logging, loads configuration, and starts the application.
"""
from dotenv import load_dotenv
load_dotenv()  # this reads .env into os.environ

import argparse
import logging
from config.config import Config  # Assuming a Config class exists
from models.masterdraft import MasterDraft
from models.usbhub import USBHub
from ui.main_window import VoxblockUI
from utils.custom_logging import setup_logging
from settings import (
    load_settings, save_settings
)



def start_app(debug=False):
    
    # Load UI settings
    # Settings is about saving previous UI values for next run of app
    # (is not settings for a Master)
    settings = load_settings()

    # Load configuration
    # Config is about app file locations and encoding settings
    config = Config()

    # draft = MasterDraft(config, settings)
    hub = USBHub()
    main_window = VoxblockUI(hub, config, settings)
    hub.ui_context = main_window


    # Start the UI (if applicable)
    main_window.run()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Voxblock Master Creation Utility")
    parser.add_argument('--debug', action='store_true', help='Use debug settings')
    args = parser.parse_args()

    start_app(args.debug)

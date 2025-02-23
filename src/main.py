"""
Main entry point for the application.
Initializes logging, loads configuration, and starts the application.
"""

import argparse
import logging
from config.config import Config  # Assuming a Config class exists
from models.master import Master
from models.usbhub import USBHub
from ui.main_window import VoxblockUI
from utils.custom_logging import setup_logging
from settings import (
    load_settings, save_settings
)

def start_app(debug=False):
    
    # Load UI settings
    settings = load_settings()


    # Load configuration
    config = Config()  # Assuming Config can accept a debug flag
    master = Master(config, settings)
    hub = USBHub()
    main_window = VoxblockUI(hub, master, settings)

    

    # Start the UI (if applicable)
    main_window.run()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Voxblock Master Creation Utility")
    parser.add_argument('--debug', action='store_true', help='Use debug settings')
    args = parser.parse_args()

    start_app(args.debug)

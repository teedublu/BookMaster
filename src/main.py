"""
Main entry point for the application.
Initializes logging, loads configuration, and starts the application.
"""

import argparse
import logging
from config.config import Config  # Assuming a Config class exists
from models.master import Master
from ui.masteruiwrapper import MasterUIWrapper  # Using the UI wrapper
from utils.custom_logging import setup_logging

def start_app(debug=False):
    """Starts the application with optional debug mode."""

    # Load configuration
    config = Config(debug=debug)  # Assuming Config can accept a debug flag

    # Initialize the master object
    master = Master(config)

    # Wrap the master object with the UI wrapper
    master_ui = MasterUIWrapper(master)

    # Start the UI (if applicable)
    master_ui.run()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Voxblock Master Creation Utility")
    parser.add_argument('--debug', action='store_true', help='Use debug settings')
    args = parser.parse_args()

    start_app(args.debug)

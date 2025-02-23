import logging

import sys
import tkinter as tk

class TextHandler(logging.Handler):
    """Custom logging handler to redirect logs to a Tkinter Text widget with colors."""
    def __init__(self, text_widget):
        super().__init__()
        self.text_widget = text_widget
        self.text_widget.configure(state='normal')

        self.colors = {
            "DEBUG": "gray",
            "INFO": "blue",
            "WARNING": "orange",
            "ERROR": "red",
            "CRITICAL": "purple",
        }

        for level, color in self.colors.items():
            self.text_widget.tag_config(level, foreground=color)

    def emit(self, record):
        """Write formatted log message to the Tkinter Text widget with color."""
        log_entry = self.format(record) + "\n"
        self.text_widget.insert("end", log_entry, record.levelname)
        self.text_widget.see("end")  # Auto-scroll



def setup_logging(text_widget):
    """Set up logging to redirect to the Tkinter Text widget."""
    logger = logging.getLogger()  # Root logger
    logger.setLevel(logging.DEBUG)

    # Create a handler for the text widget
    text_handler = TextHandler(text_widget)
    text_handler.setFormatter(logging.Formatter("%(levelname)-7s: %(message)s"))

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(logging.Formatter("%(levelname)-8s: %(message)s"))


    # Remove old handlers to prevent duplicate logs
    if logger.hasHandlers():
        logger.handlers.clear()

    logger.addHandler(text_handler)  # Logs to Tkinter Text Box
    logger.addHandler(console_handler)  # Logs to stdout (console)

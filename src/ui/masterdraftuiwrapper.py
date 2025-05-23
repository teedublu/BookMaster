import tkinter as tk
import logging
import csv
from tkinter import messagebox, filedialog
from tkinter.scrolledtext import ScrolledText
from utils.custom_logging import setup_logging, TextHandler
from models import MasterDraft  # Import Master class
from utils import find_input_folder_from_isbn, parse_time_to_minutes
from utils import remove_folder, compute_sha256, get_first_audiofile, get_metadata_from_audio, generate_sku, generate_isbn
from utils import MasterValidator
class MasterDraftUIWrapper:
    """
    Wrapper class for managing Tkinter UI state while keeping Master logic separate.
    """

    VARIABLE_TYPES = {
        str: lambda value="": tk.StringVar(value=value),
        int: lambda value=0: tk.IntVar(value=value),
        bool: lambda value=False: tk.BooleanVar(value=value),
        float: lambda value=0.0: tk.DoubleVar(value=value),
        list: lambda value=[]: tk.StringVar(value=",".join(value)),
    }

    def __init__(self, main_window, config, settings):
        self.main_window = main_window
        self.root = main_window.root
        self.config = config
        # set the last used values on load
        self.isbn = settings.get("past_master", {}).get("isbn", "")
        self.sku = settings.get("past_master", {}).get("sku", "")
        self.title = settings.get("past_master", {}).get("title", "")
        self.author = settings.get("past_master", {}).get("author", "")
        self.input_folder = settings.get("input_folder", None)
        self.expected_count = None
        
        # included for now until unpicked
        self.file_count_expected = None
        self.file_count_observed = None
        self.status = None
        self.skip_encoding = None
        self.duration = None

        self.settings = settings
        
        print (self.get_fields().items())
        # Create Tkinter variables dynamically
        self._vars = {
            key: self.VARIABLE_TYPES[type(value) if value is not None else str](value if value is not None else "")
            for key, value in self.get_fields().items()
        }


        # Attach trace_add to each variable to sync with Master instance
        for key, var in self._vars.items():
            var.trace_add("write", self._on_var_change(key))


        # Dynamically create properties that sync with Tkinter variables
        for key in self._vars:
            setattr(self.__class__, key, property(
                lambda self, k=key: self._vars[k].get(),
                lambda self, value, k=key: self._vars[k].set(value)
            ))

        self._callbacks = {
            "isbn": self._on_isbn_change
        }


    def loadMasterDraft(self):
        
        self.draft = MasterDraft(self.config, self.settings, self.isbn, self.sku, self.author, self.title, self.expected_count, self.input_folder)

    def _on_var_change(self, key):
        """Creates a callback function for trace_add to sync UI changes with Master."""
        def callback(*args):
            new_value = self._vars[key].get()
            if getattr(self, key, None) != new_value:  # Prevent infinite loops
                logging.debug(f"Syncing UI change: {key} -> {new_value}")
                setattr(self, key, new_value)

            # Trigger additional callbacks if needed
            if key in self._callbacks:
                self._callbacks[key](new_value)

        return callback


    # Inline lookup function
    def _on_isbn_change(self, *args):
        if not self.main_window.lookup_csv_var.get():
            logging.debug(f"csv lookup disabled")
            return

        new_isbn = self._vars["isbn"].get()
        
        """Triggered when ISBN changes. Looks up book details if ISBN is 13 digits."""
        if not isinstance(new_isbn, str) or len(new_isbn) != 13 or not new_isbn.isdigit():
            logging.debug(f"Invalid ISBN '{new_isbn}': must be 13 digits.")
            return

        logging.info(f"Looking up data for {new_isbn}")

        row = self.main_window.config.books.get(new_isbn, {})  # Fast lookup from cached dictionary

        if not row:
            logging.warning(f"No data found for {new_isbn}")
            self._vars["sku"].set("")
            self._vars["title"].set("")
            self._vars["author"].set("")
            self._vars["file_count_expected"].set(0)
            self._vars["duration"].set(0.0)
            return

        logging.debug(f"Data found for {new_isbn} {row}")


        self._vars["sku"].set(row.get('SKU', ""))
        self._vars["title"].set(row.get('Title', ""))
        self._vars["author"].set(row.get('Author', ""))
        self._vars["file_count_expected"].set(row.get('ExpectedFileCount', 0))
        self._vars["duration"].set(parse_time_to_minutes(row.get('Duration')))
        


    def update_ui_from_master(self):
        """Ensures UI reflects the current state of Master."""
        for key in self._vars:
            master_value = getattr(self.draft, key, None)
            ui_value = self._vars[key].get()
            

            if master_value != ui_value:  # Prevent redundant updates
                logging.debug(f"Syncing Master change to UI: {key} -> {master_value}")
                self._vars[key].set(master_value)


    def update_master_from_ui(self):
        """Syncs Master instance properties with Tkinter variables."""
        for key in self._vars:
            setattr(self.draft, key, self._vars[key].get())

    def _on_usb_tests_change(self, *_):
        """Updates Master when the UI checkboxes change."""
        self.draft.usb_drive_tests = self._vars["usb_drive_tests"].get().split(",")
        self.draft.logger.info(f"Updated USB drive tests: {self.draft.usb_drive_tests}")


    def select_input_folderOLD(self):
        """Opens a folder selection dialog, updates the corresponding Tkinter variable, and creates a Master from the input folder."""
        folder_selected = filedialog.askdirectory()
        if folder_selected:
            setattr(self.draft, "input_folder", folder_selected)
            self.draft.load_input_tracks(folder_selected)  # Load tracks from the folder
            self.draft.process_tracks()
            self.draft.validate_master()
            # self.update_ui_from_master()
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

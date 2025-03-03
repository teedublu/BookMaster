import tkinter as tk
import logging
import csv
from tkinter import messagebox, filedialog
from tkinter.scrolledtext import ScrolledText
from utils.custom_logging import setup_logging, TextHandler
from models import Master  # Import Master class
from utils import find_input_folder_from_isbn, parse_time_to_minutes
from utils import MasterValidator
class MasterUIWrapper:
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

    def __init__(self, main_window, master_instance, settings):
        self.master = master_instance
        self.main_window = main_window
        self.root = main_window.root
        self.config = master_instance.config
        # set the last used values on load
        self.master.isbn = settings.get("past_master", {}).get("isbn", "")
        self.master.sku = settings.get("past_master", {}).get("sku", "")
        self.master.title = settings.get("past_master", {}).get("title", "")
        self.master.author = settings.get("past_master", {}).get("author", "")
        self.settings = settings
        # self.settings_copy = {k: v for k, v in master_instance.settings.items() if k != "past_master"} # remove past_master - UI settings should not be passed to master NEEDS REFACTORING SO settings go to MasterUIWrapper not Master
        
        # Create Tkinter variables dynamically
        self._vars = {
            key: self.VARIABLE_TYPES[type(value)](value=value)
            for key, value in self.master.get_fields().items()
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

    def _rebind_master(self):
        """Rebinds the UI to a new Master instance."""
        # Update internal variables with new Master fields
        for key, var in self._vars.items():
            if key in self.master.get_fields():
                var.set(self.master.get_fields()[key])
    
        # Ensure UI callbacks are still attached
        for key, var in self._vars.items():
            var.trace_add("write", self._on_var_change(key))


    def check(self):
        """Validates Master and updates UI."""
        tests = self.main_window.usb_drive_tests_var.get()
        self.validator = MasterValidator(self.main_window.usb_hub.first_available_drive, tests=tests)


    def create(self):
        self.settings["isbn"] = self._vars["isbn"].get()
        self.settings["sku"] = self._vars["sku"].get()
        self.settings["title"] = self._vars["title"].get()
        self.settings["author"] = self._vars["author"].get()
        self.settings["file_count_expected"] = self._vars["file_count_expected"].get()

        self.master = Master(self.config, self.settings) #### Pass isb and sku here not via past master
        input_folder = self.main_window.input_folder_var.get()

        if self.main_window.find_isbn_folder_var.get():
            try:
                input_folder = find_input_folder_from_isbn(self, input_folder, self.isbn)
            except Exception as e:
                logging.error(f"Finding folder with isbn {self.isbn} failed. Stopping.")
                return

        usb_drive = self.main_window.usb_hub.first_available_drive

        logging.info(f"Passing '{input_folder}' to create a Master on {usb_drive}")
        self.master.create(input_folder, usb_drive)

    def _on_var_change(self, key):
        """Creates a callback function for trace_add"""
        def callback(*args):
            new_value = self._vars[key].get()
            logging.debug(f"Updated Master {key} -> {new_value}")
            setattr(self.master, key, new_value)
            if key in self._callbacks:
                self._callbacks[key](new_value)

        return callback

    # Inline lookup function
    def _on_isbn_change(self, *args):
        new_isbn = self._vars["isbn"].get()
        
        """Triggered when ISBN changes. Looks up book details if ISBN is 13 digits."""
        if len(new_isbn) != 13 :
            logging.debug(f"Invalid ISBN {new_isbn} len={len(new_isbn)}")
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
        """Syncs Tkinter variables with Master instance properties."""
        for key in self._vars:
            self._vars[key].set(getattr(self.master, key))

    def update_master_from_ui(self):
        """Syncs Master instance properties with Tkinter variables."""
        for key in self._vars:
            setattr(self.master, key, self._vars[key].get())

    def _on_usb_tests_change(self, *_):
        """Updates Master when the UI checkboxes change."""
        self.master.usb_drive_tests = self._vars["usb_drive_tests"].get().split(",")
        self.master.logger.info(f"Updated USB drive tests: {self.master.usb_drive_tests}")


    def select_input_folder(self):
        """Opens a folder selection dialog, updates the corresponding Tkinter variable, and creates a Master from the input folder."""
        folder_selected = filedialog.askdirectory()
        if folder_selected:
            setattr(self.master, "input_folder", folder_selected)
            self.master.load_input_tracks(folder_selected)  # Load tracks from the folder
            self.master.process_tracks()
            self.master.validate_master()
            # self.update_ui_from_master()


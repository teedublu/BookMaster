import tkinter as tk
import logging
import csv
from tkinter import messagebox, filedialog
from tkinter.scrolledtext import ScrolledText
from utils.custom_logging import setup_logging, TextHandler
from models import Master  # Import Master class

class MasterUIWrapper:
    """
    Wrapper class for managing Tkinter UI state while keeping Master logic separate.
    """

    VARIABLE_TYPES = {
        str: lambda value="": tk.StringVar(value=value),
        int: lambda value=0: tk.IntVar(value=value),
        bool: lambda value=False: tk.BooleanVar(value=value),
        float: lambda value=0.0: tk.DoubleVar(value=value),
    }

    def __init__(self, main_window, master_instance):
        self.master = master_instance
        self.main_window = main_window
        self.root = main_window.root
        
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
            "isbn": self._on_isbn_change,
            "csv_lookup": self._on_csv_lookup_change,
        }

        self.books_data = self._load_books_csv()  # Load books.csv once

    def check(self):
        """Validates Master and updates UI."""
        self.master.check()
        self.update_ui()


    def _on_var_change(self, key):
        """Creates a callback function for trace_add"""
        def callback(*args):
            new_value = self._vars[key].get()
            
            if key in self._callbacks:
                self._callbacks[key](new_value)

        return callback

    # Inline lookup function
    def _on_isbn_change(self, *args):
        new_isbn = self.isbn_var.get()

        """Triggered when ISBN changes. Looks up book details if ISBN is 13 digits."""
        if len(new_isbn) != 13 or not self.main_window.lookup_csv_var.get():
            logging.debug(f"Invalid ISBN {self.master.isbn} {args[0]}")
            return

        logging.info(f"Looking up data for {self.master.isbn}")

        row = self.books_data.get(self.master.isbn, {})  # Fast lookup from cached dictionary

        if not row:
            logging.warning(f"No data found for {self.master.isbn}")
            self.master.sku = None
            self.master.title = None
            self.master.author = None
            self.master.expected_file_count = None
            self.master.duration = None
            return

        self.master.sku = row.get('SKU', None)
        self.master.title = row.get('Title', None)
        self.master.author = row.get('Author', None)
        self.master.expected_file_count = row.get('ExpectedFileCount', None)
        




    def _on_csv_lookup_change(self, key):
        """Call _on_isbn_change if csv_lookup is checked"""
        if self.csv_lookup:  # Check if the checkbox is checked
            self._on_isbn_change(key)  # Call the other function



    def update_ui_from_master(self):
        """Syncs Tkinter variables with Master instance properties."""
        for key in self._vars:
            self._vars[key].set(getattr(self.master, key))

    def update_master_from_ui(self):
        """Syncs Master instance properties with Tkinter variables."""
        for key in self._vars:
            setattr(self.master, key, self._vars[key].get())

    
    def select_input_folder(self):
        """Opens a folder selection dialog, updates the corresponding Tkinter variable, and creates a Master from the input folder."""
        folder_selected = filedialog.askdirectory()
        if folder_selected:
            setattr(self.master, "input_folder", folder_selected)
            self.master.load_input_tracks(folder_selected)  # Load tracks from the folder
            self.master.process_tracks()
            self.master.validate_master()
            # self.update_ui_from_master()

    def _load_books_csv(self):
        """Loads books.csv into memory as a dictionary for quick lookup."""
        books = {}
        try:
            with open('books.csv', 'r', encoding='utf-8') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    isbn = row.get('ISBN')
                    if isbn:
                        books[isbn] = row  # Store row with ISBN as key
            logging.info("Loaded books.csv into memory.")
        except FileNotFoundError:
            logging.error("Error: books.csv not found.")
        except Exception as e:
            logging.error(f"Error reading books.csv: {e}")
        return books  # Return empty dict if file is missing


    
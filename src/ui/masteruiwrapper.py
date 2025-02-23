import tkinter as tk
import logging
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

    def __init__(self, root, master_instance):
        self.master = master_instance
        self.root = root
        
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

    def check(self):
        """Validates Master and updates UI."""
        self.master.check()
        self.update_ui()

    def _on_var_change(self, key):
        """Sync changes from Tkinter variables back to the Master instance."""
        def callback(*args):
            print (f"Updating master {key} with {self._vars[key].get()}")
            setattr(self.master, key, self._vars[key].get())
        return callback

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

    
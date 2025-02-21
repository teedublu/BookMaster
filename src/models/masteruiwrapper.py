import tkinter as tk

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

    def __init__(self, master_instance):
        self.master = master_instance

        # Create Tkinter variables dynamically
        self._vars = {
            key: self.VARIABLE_TYPES[type(value)](value=value)
            for key, value in self.master.fields.items()
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

    def _on_var_change(self, key):
        """Sync changes from Tkinter variables back to the Master instance."""
        def callback(*args):
            self.master.fields[key] = self._vars[key].get()
        return callback

    def update_ui_from_master(self):
        """Syncs Tkinter variables with Master instance fields."""
        for key in self._vars:
            self._vars[key].set(self.master.fields[key])

    def update_master_from_ui(self):
        """Syncs Master instance fields with Tkinter variables."""
        for key in self._vars:
            self.master.fields[key] = self._vars[key].get()

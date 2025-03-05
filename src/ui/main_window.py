# ui.py
import os
import tkinter as tk
from tkinter import messagebox, filedialog
from tkinter.scrolledtext import ScrolledText
import logging
from pathlib import Path
from utils.webcam import Webcam


from utils.custom_logging import setup_logging
from ui.masteruiwrapper import MasterUIWrapper
from settings import save_settings

class VoxblockUI:
    def __init__(self, usb_hub, master, config, settings):
        self.root = tk.Tk()
        self.config = config
        self.settings = settings
        self.webcam = None
        self.usb_hub = usb_hub
        self.usb_hub.callback = self.update_usb_list
        self.settings = settings
        # Initialize UI state variables that are not passed to Master and used only in UI to prepare
        # eg variable=self.lookup_csv_var
        # versus variable=self.master_ui._vars["infer_data"]
        self.input_folder_var = tk.StringVar(value=settings.get('input_folder', None))
        self.find_isbn_folder_var = tk.BooleanVar(value=settings.get('find_isbn_folder', False))
        self.lookup_csv_var = tk.BooleanVar(value=settings.get('lookup_csv', False))
        self.usb_drive_check_on_mount = tk.BooleanVar(value=settings.get('usb_drive_check_on_mount', False))
        self.usb_drive_tests_var = tk.StringVar(value=settings.get('usb_drive_tests', ""))  # Comma-separated string

        # Define available tests dynamically
        self.available_tests = ["Silence", "Loudness", "Metadata", "Frames", "Speed"]
        self._checkbox_vars = {
            test: tk.BooleanVar(value=(test in self.usb_drive_tests_var.get().split(","))) 
            for test in self.available_tests
        }

        # Attach trace_add to sync checkboxes when changed
        for test, var in self._checkbox_vars.items():
            var.trace_add("write", self._sync_checkboxes_to_string)


        # Wrap the master object with the UI wrapper
        self.master_ui = MasterUIWrapper(self, master, settings)
        
        self.create_widgets()
        self._sync_string_to_checkboxes()

        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

    def create_widgets(self):
        """Creates the UI layout"""
        self.root.title("Voxblock Master Creation App")
        self.root.geometry("800x800")


        ############ ROW 0
        # Input Folder
        tk.Label(self.root, text="Input Folder:").grid(row=0, column=0, sticky='w')
        tk.Entry(self.root, textvariable=self.input_folder_var).grid(row=0, column=1, sticky='w')
        tk.Button(self.root, text="Browse", command=lambda: self.browse_folder(self.input_folder_var)).grid(row=0, column=2)
        # option to scan for folder
        tk.Checkbutton(self.root, text="Find input from ISBN", variable=self.find_isbn_folder_var).grid(row=0, column=3, sticky='w')

        ############ ROW 1
        tk.Checkbutton(self.root, text="Skip encoding", variable=self.master_ui._vars["skip_encoding"]).grid(row=1, column=3, sticky='w')

        ############ ROW 3
        # ISBN Entry
        tk.Label(self.root, text="ISBN:").grid(row=3, column=0, sticky='w')
        self.isbn_entry = tk.Entry(self.root, textvariable=self.master_ui._vars["isbn"])
        self.isbn_entry.grid(row=3, column=1, sticky='w')
        # Radio button for Webcam
        self.use_webcam_field = tk.BooleanVar(value=False) 
        tk.Checkbutton(self.root, text="Use Webcam to Detect ISBN", variable=self.use_webcam_field, command=self.toggle_webcam).grid(row=3, column=3, sticky='w')

        ############ ROW 4
        # SKU Entry
        tk.Label(self.root, text="SKU:").grid(row=4, column=0, sticky='w')
        self.sku_entry = tk.Entry(self.root, textvariable=self.master_ui._vars["sku"], state='normal')
        self.sku_entry.grid(row=4, column=1, sticky='w')
        # Radio button for CSV lookup
        self.lookup_csv_field = tk.Checkbutton(self.root, text="CSV lookup", variable=self.lookup_csv_var, command=self.toggle_csvlookup)
        self.lookup_csv_field.grid(row=4, column=3, sticky='w')

        ############ ROW 5
        # Title Entry
        tk.Label(self.root, text="Title:").grid(row=5, column=0, sticky='w')
        self.title_entry = tk.Entry(self.root, textvariable=self.master_ui._vars["title"], state='normal')
        self.title_entry.grid(row=5, column=1, sticky='w')
        # Radio button for CSV lookup
        self.infer_data_field = tk.Checkbutton(self.root, text="Infer data", variable=self.master_ui._vars["infer_data"])
        self.infer_data_field.grid(row=5, column=3, sticky='w')

        ############ ROW 6
        # Author Entry
        tk.Label(self.root, text="Author:").grid(row=6, column=0, sticky='w')
        self.author_entry = tk.Entry(self.root, textvariable=self.master_ui._vars["author"], state='normal')
        self.author_entry.grid(row=6, column=1, sticky='w')

        ############ ROW 7
        # File Count Entry
        tk.Label(self.root, text="Expected File Count:").grid(row=7, column=0, sticky='w')
        self.file_count = tk.Entry(self.root, textvariable=self.master_ui._vars["file_count_expected"], state='normal')
        self.file_count.grid(row=7, column=1, sticky='w')

        ############ ROW 8
        # Create Button
        self.create_master_button = tk.Button(self.root, text="Create Master", command=self.create)
        self.create_master_button.grid(row=8, column=0, columnspan=2)
        # Create Button
        self.check_master_button = tk.Button(self.root, text="Check Master", command=self.master_ui.check)
        self.check_master_button.grid(row=8, column=2, columnspan=2)

        ############ ROW 9
        # Webcam panel
        self.webcam_frame = tk.LabelFrame(self.root, borderwidth=2, relief="groove", text="Webcam")
        self.webcam_frame.grid(row=9, column=0, columnspan=2, padx=10, pady=10, sticky="nsew")
        # USB Drives Panel
        self.usbdrives_frame = tk.LabelFrame(self.root, borderwidth=2, relief="groove", text="Waiting for USB devices...")
        self.usbdrives_frame.grid(row=9, column=2, columnspan=1, padx=10, pady=10, sticky="nsew")
        self.usb_listbox = tk.Listbox(self.usbdrives_frame, height=5)
        self.usb_listbox.grid(row=0, column=0, rowspan=10, sticky='w')

        tk.Checkbutton(self.usbdrives_frame, text="Check on mount", variable=self.usb_drive_check_on_mount).grid(row=0, column=1, sticky='w')
        # tk.Checkbutton(self.usbdrives_frame, text="Silence", variable=self.usb_drive_tests_silence).grid(row=1, column=1, sticky='w')
        # tk.Checkbutton(self.usbdrives_frame, text="Loudness", variable=self.usb_drive_tests_loudness).grid(row=2, column=1, sticky='w')
        # tk.Checkbutton(self.usbdrives_frame, text="Metadata", variable=self.usb_drive_tests_metadata).grid(row=3, column=1, sticky='w')
        # tk.Checkbutton(self.usbdrives_frame, text="Frames", variable=self.usb_drive_tests_frames).grid(row=4, column=1, sticky='w')
        # tk.Checkbutton(self.usbdrives_frame, text="Speed", variable=self.usb_drive_tests_speed).grid(row=5, column=1, sticky='w')

        for i, test in enumerate(self.available_tests):
            tk.Checkbutton(self.usbdrives_frame, text=test, variable=self._checkbox_vars[test], command=self.update_selected_tests).grid(row=i+1, column=1, sticky='w')


        ############ ROW 10
        self.video_label = tk.Label(self.webcam_frame, relief='solid', borderwidth=2)
        self.video_label.grid(row=10, column=0, columnspan=2)



        ############ ROW 13
        # FEEDBACK OUTPUT
        self.log_text = ScrolledText(self.root, height=30, width=100, state='normal', wrap="none")
        self.log_text.grid(row=13, column=0, columnspan=4)
        setup_logging(self.log_text)

    def create(self):
        self.master_ui.create()

    def refresh_ui(self):
        """Refresh the UI after a Master instance is replaced."""
        self.root.update_idletasks()

    def update_selected_tests(self):
        """Updates self.usb_drive_tests_var when checkboxes change."""
        selected_tests = [test for test, var in self._checkbox_vars.items() if var.get()]
        self.usb_drive_tests_var.set(",".join(selected_tests))  # Update StringVar
        self.settings["usb_drive_tests"] = self.usb_drive_tests_var.get()  # Sync with settings
        print(f"Updated tests: {self.usb_drive_tests_var.get()}")  # Debugging output

    def toggle_csvlookup(self):
        new_state = "readonly" if self.lookup_csv_var.get() else "normal"
        # logging.debug(f"CSV changed to {new_state}")
        self.title_entry.config(state=new_state)
        self.author_entry.config(state=new_state)
        self.sku_entry.config(state=new_state)
        self.file_count.config(state=new_state)
        if self.lookup_csv_var.get():
            self.master_ui._on_isbn_change()

    def test_selected_drive(self):
        """Trigger a test on the selected USB drive."""
        selected_index = self.usb_listbox.curselection()
        if not selected_index:
            messagebox.showwarning("No Drive Selected", "Please select a USB drive to test.")
            return
        selected_drive = self.usb_listbox.get(selected_index[0])
        
        if selected_drive in self.usb_hub.drives:
            result = self.usb_hub.drives[selected_drive].get_capacity()
            messagebox.showinfo("Drive Test", result)
        else:
            messagebox.showerror("Error", "Selected drive not found.")

    def update_usb_list(self, drives):
        if not hasattr(self, 'usb_listbox') or self.usb_listbox is None:
            print("Error: self.usb_listbox is None!")  # Debugging
            return  # Ensure listbox exists before updating
        
        self.usb_listbox.delete(0, tk.END)
        for drive in drives:
            self.usb_listbox.insert(tk.END, drive)

        if drives:
            self.usb_listbox.selection_set(0)  # Select the first drive automatically
            self.usb_listbox.activate(0)

        self.usbdrives_frame.config(text="Write to..." if drives else "No drives detected.")


    def toggle_webcam(self):
        print('Toggling webcam...')  # Debug feedback
        if self.use_webcam_field.get():
            if not self.webcam:
                self.webcam = Webcam(self.video_label, self.update_isbn)
                self.webcam.start()
                print('Webcam started.')  # Debug feedback
            self.isbn_entry.config(state='readonly')
        else:
            if self.webcam:
                self.webcam.stop()
                self.webcam = None
                self.video_label.config(image='')
                self.video_label.config(text='Webcam Off')
                self.video_label.update_idletasks()  # Force the UI to update immediately
            self.isbn_entry.config(state='normal')

    def update_isbn(self, barcode_data):
        """Callback function to update the ISBN entry"""
        if len(barcode_data) == 13 and barcode_data.isdigit():
            self.master_ui._vars["isbn"].set(barcode_data)

    def browse_folder(self, field):
        """Opens a folder selection dialog, starting in the current folder value."""
        current_value = field.get()  # Get current folder path from UI field

        # Ensure the initial directory is valid (fallback to home directory)
        initial_dir = current_value if current_value and os.path.isdir(current_value) else os.path.expanduser("~")

        folder_selected = filedialog.askdirectory(initialdir=initial_dir)  # Start dialog in the current folder
        if folder_selected:
            field.set(folder_selected)  # Update UI field with selected folder

    def _sync_checkboxes_to_string(self, *_):
        """Update the StringVar to match selected checkboxes."""
        selected_tests = [test for test, var in self._checkbox_vars.items() if var.get()]
        self.usb_drive_tests_var.set(",".join(selected_tests))

    def _sync_string_to_checkboxes(self, *_):
        """Update checkboxes based on the stored StringVar."""
        selected_tests = self.usb_drive_tests_var.get().split(",")
        for test, var in self._checkbox_vars.items():
            var.set(test in selected_tests)


    def run(self):
        """Runs the Tkinter main loop."""
        self.root.mainloop()

    def update_settings(self):
        """Updates settings from UI variables."""
        self.settings['input_folder'] = self.input_folder_var.get()
        self.settings['find_isbn_folder'] = self.find_isbn_folder_var.get()
        self.settings['lookup_csv'] = self.lookup_csv_var.get()
        self.settings['infer_data'] = self.master_ui._vars["infer_data"].get()
        self.settings['skip_encoding'] = self.master_ui._vars["skip_encoding"].get()

        self.settings['usb_drive_check_on_mount'] = self.usb_drive_check_on_mount.get()
        self.settings['usb_drive_tests'] = self.usb_drive_tests_var.get()  # Save as a string

        self.settings['past_master'] = {
            'isbn': self.master_ui._vars["isbn"].get(),
            'sku': self.master_ui._vars["sku"].get(),
            'author': self.master_ui._vars["author"].get(),
            'title': self.master_ui._vars["title"].get()
        }

    def on_closing(self):
        """Saves settings and exits the application."""
        self.update_settings()  # Ensure settings are updated before saving
        save_settings(self.settings)  # Pass app.settings instead of app
        self.root.destroy()



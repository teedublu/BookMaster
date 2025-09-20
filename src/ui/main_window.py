# ui.py
import os, csv
import tkinter as tk
from tkinter import messagebox, filedialog
from tkinter.scrolledtext import ScrolledText
import logging
from pathlib import Path
from utils.webcam import Webcam
from models import Master
from utils import find_input_folder_from_isbn, parse_time_to_minutes
from utils.custom_logging import setup_logging
from ui.masterdraftuiwrapper import MasterDraftUIWrapper
from models import MasterDraft, MasterValidator  # Import Master class
from settings import save_settings

class VoxblockUI:
    def __init__(self, usb_hub, config, settings):
        self.root = tk.Tk()
        self.config = config
        self.settings = settings
        self.webcam = None
        self.usb_hub = usb_hub
        self.usb_hub.callback = self.update_usb_list
        self.settings = settings

        # Initialize UI state variables that are not passed to Master and used only in UI to prepare
        # eg variable=self.lookup_csv_var
        # versus variable=self.ui_state["infer_data"]
        # self.input_folder_var = tk.StringVar(value=settings.get('input_folder', None))
        # self.find_isbn_folder_var = tk.BooleanVar(value=settings.get('find_isbn_folder', False))
        self.lookup_csv_var = tk.BooleanVar(value=settings.get('lookup_csv', False))
        self.usb_drive_check_on_mount = tk.BooleanVar(value=settings.get('usb_drive_check_on_mount', False))
        self.usb_drive_tests_var = tk.StringVar(value=settings.get('usb_drive_tests', ""))  # Comma-separated string
        self.draft = MasterDraft(config, settings)

        self.ui_state = {
            "find_isbn_folder": tk.BooleanVar(value=settings.get("find_isbn_folder", False)),
            "lookup_csv": tk.BooleanVar(value=settings.get("lookup_csv", False)),
            "usb_drive_check_on_mount": tk.BooleanVar(value=settings.get("usb_drive_check_on_mount", False)),
            "usb_drive_tests": tk.StringVar(value=settings.get("usb_drive_tests", "")),
            "skip_encoding": tk.BooleanVar(value=settings.get("skip_encoding", False))
        }
        past_master = settings.get("past_master",{})
        self.draft_vars = {
            "isbn": tk.StringVar(value=past_master.get('isbn', None)),
            "title": tk.StringVar(value=past_master.get('title', None)),
            "author": tk.StringVar(value=past_master.get("author",None)),
            "sku": tk.StringVar(value=past_master.get("sku",None)),
            "input_folder": tk.StringVar(value=past_master.get("input_folder",None)),
            "file_count_expected": tk.IntVar(value=past_master.get("file_count_expected", 0))
        }

        
        self._callbacks = {
            "isbn": self._on_isbn_change
        }

        # def make_tracer(k, v):
        #     return lambda *_: setattr(self.draft, k, v.get())

        # for key, var in self.draft_vars.items():
        #     var.trace_add("write", make_tracer(key, var))

        for key, var in self.draft_vars.items():
            var.trace_add("write", self._on_var_change(key))


        # set to force sync first time
        for key, var in self.draft_vars.items():
            setattr(self.draft, key, var.get())



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
        # self.draft = MasterDraftUIWrapper(self, config, settings)
        
        
        self.create_widgets()
        self._sync_string_to_checkboxes()

        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

    def _on_var_change(self, key):
        """Creates a callback function for trace_add to sync UI changes with Master."""
        def callback(*args):
            new_value = self.draft_vars[key].get()
            if getattr(self, key, None) != new_value:  # Prevent infinite loops
                logging.debug(f"Syncing UI change: {key} -> {new_value}")
                setattr(self.draft, key, new_value)

            # Trigger additional callbacks if needed
            if key in self._callbacks:
                self._callbacks[key](new_value)
        
        return callback

    def create_widgets(self):
        """Creates the UI layout"""
        self.root.title("Voxblock Master Creation App")
        self.root.geometry("800x800")


        ############ ROW 0
        # Input Folder
        tk.Label(self.root, text="Input Folder:").grid(row=0, column=0, sticky='w')
        tk.Entry(self.root, textvariable=self.draft_vars["input_folder"]).grid(row=0, column=1, columnspan=2, sticky='we')
        tk.Button(self.root, text="Browse", command=lambda: self.browse_folder(self.draft_vars["input_folder"])).grid(row=0, column=3, sticky='w')
        
        ############ ROW 1
        
        tk.Checkbutton(self.root, text="Skip encoding", variable=self.ui_state["skip_encoding"]).grid(row=1, column=3, sticky='w')

        ############ ROW 3
        # ISBN Entry
        tk.Label(self.root, text="ISBN:").grid(row=3, column=0, sticky='w')
        self.isbn_entry = tk.Entry(self.root, textvariable=self.draft_vars["isbn"]).grid(row=3, column=1, sticky='w')
        # option to scan for folder
        tk.Checkbutton(self.root, text="Find input from ISBN", variable=self.ui_state["find_isbn_folder"]).grid(row=3, column=2, sticky='w')

        # Radio button for Webcam
        self.use_webcam_field = tk.BooleanVar(value=False) 
        tk.Checkbutton(self.root, text="Use Webcam to Detect ISBN", variable=self.use_webcam_field, command=self.toggle_webcam).grid(row=3, column=3, sticky='w')

        ############ ROW 4
        # SKU Entry
        tk.Label(self.root, text="SKU:").grid(row=4, column=0, sticky='w')
        self.sku_entry = tk.Entry(self.root, textvariable=self.draft_vars["sku"], state='normal')
        self.sku_entry.grid(row=4, column=1, sticky='w')
        # Radio button for CSV lookup
        self.lookup_csv_field = tk.Checkbutton(self.root, text="CSV lookup", variable=self.lookup_csv_var, command=self.toggle_csvlookup)
        self.lookup_csv_field.grid(row=4, column=3, sticky='w')

        ############ ROW 5
        # Title Entry
        tk.Label(self.root, text="Title:").grid(row=5, column=0, sticky='w')
        self.title_entry = tk.Entry(self.root, textvariable=self.draft_vars["title"], state='normal')
        self.title_entry.grid(row=5, column=1, sticky='w')
        tk.Button(self.root, text="Batch Create from CSV", command=lambda: self.load_isbn_csv_and_create_masters()).grid(row=5, column=3, sticky='w')
        
        ############ ROW 6
        # Author Entry
        tk.Label(self.root, text="Author:").grid(row=6, column=0, sticky='w')
        self.author_entry = tk.Entry(self.root, textvariable=self.draft_vars["author"], state='normal')
        self.author_entry.grid(row=6, column=1, sticky='w')

        ############ ROW 7
        # File Count Entry
        tk.Label(self.root, text="File Count:").grid(row=7, column=0, sticky='w')
        self.file_count = tk.Entry(self.root, textvariable=self.draft_vars["file_count_expected"], state='normal')
        self.file_count.grid(row=7, column=1, sticky='w')

        ############ ROW 8
        # Create Button
        self.create_master_button = tk.Button(self.root, text="Create Master", command=self.create)
        self.create_master_button.grid(row=8, column=0, columnspan=2)
        # Check Button
        self.check_master_button = tk.Button(self.root, text="Check Master", command=self.check)
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
        input_folder = self.get_input_folder()
        if input_folder:
            self.draft.input_folder = self.get_input_folder()
            self.draft.skip_encoding = self.ui_state["skip_encoding"].get()
            output_path = Path(self.settings["output_folder"])
            errors = self.draft.validate()
            if errors:
                logging.error(f"Invalid Input Folder {errors}")
                return
            else:
                self.draft.load_tracks()
                self.master = self.draft.to_master(output_path)
                

            selected_index = self.usb_listbox.curselection()
            if selected_index:
                selected_drive = self.usb_listbox.get(selected_index[0])
                if selected_drive in self.usb_hub.drives and false: #blocked for now!!!!!!!!!!!!!!!!!!!!!
                    usb_drive = self.usb_hub.drives[selected_drive]
                    usb_drive.write_disk_image(self.master.image_file)
        else:
            logging.error(f"Input folder {input_folder} not found")
                
    def check(self):
        # path = "/Users/thomaswilliams/Documents/VoxblockMaster/output/BK-74107-CLAE/master"

        self.reset()

        # self.draft = MasterDraft.from_file(self.config, self.settings, path, tests=None) #from_device defines the checks to be made
        
        self.draft.input_folder = self.get_input_folder()
        selected_index = self.usb_listbox.curselection()
        if selected_index:
            selected_drive = self.usb_listbox.get(selected_index[0])
            if selected_drive in self.usb_hub.drives:
                usb_drive = self.usb_hub.drives[selected_drive]
                # loads details from drive
                usb_drive.load_existing()
                self.update_settings

                logging.debug(f"Loaded existing Master")
                tests = self.available_tests
                self.draft.input_folder = usb_drive.mountpoint
                
                print (self.draft.validate())
                # self.candidate_master = MasterDraft
                self.candidate_master = Master.from_device(self.config, self.settings, usb_drive.mountpoint, tests) #from_device defines the checks to be made



        else:
            logging.warning(f"No usb drive selected")

    def get_input_folder(self):
        input_folder = self.draft_vars["input_folder"].get()
        isbn = self.draft_vars["isbn"].get()
        find_isbn_folder = self.ui_state["find_isbn_folder"].get()
        if find_isbn_folder:
            logging.debug(f"Finding folder based on {isbn}")
            try:
                return find_input_folder_from_isbn(self, input_folder, isbn)
            except ValueError:
                return None
        else:
            return input_folder

    def refresh_ui(self):
        """Refresh the UI after a Master instance is replaced."""
        self.root.update_idletasks()

    def reset(self):
        
        # set to force sync first time
        for key, var in self.draft_vars.items():
            # setattr(self.draft, key, None)
            if key == "file_count_expected":
                self.draft_vars[key].set(0)
            elif key!="input_folder":
                self.draft_vars[key].set(None)

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
            self._on_isbn_change()

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
                print('Webcam started.')
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
            self.draft_vars["isbn"].set(barcode_data)

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
        self.settings['find_isbn_folder'] = self.ui_state["find_isbn_folder"].get()
        self.settings['lookup_csv'] = self.ui_state["lookup_csv"].get()
        self.settings['skip_encoding'] = self.ui_state["skip_encoding"].get()

        self.settings['usb_drive_check_on_mount'] = self.ui_state["usb_drive_check_on_mount"].get()
        self.settings['usb_drive_tests'] = self.ui_state["usb_drive_tests"].get()  # Save as a string

        self.settings['past_master'] = {
            'isbn': self.draft_vars["isbn"].get(),
            'sku': self.draft_vars["sku"].get(),
            'author': self.draft_vars["author"].get(),
            'title': self.draft_vars["title"].get(),
            'input_folder': self.draft_vars["input_folder"].get()
        }

    def on_closing(self):
        """Saves settings and exits the application."""
        self.update_settings()  # Ensure settings are updated before saving
        save_settings(self.settings)  # Pass app.settings instead of app
        self.root.destroy()

    # Inline lookup function
    def _on_isbn_change(self, *args):

        if not self.lookup_csv_var.get():
            logging.debug(f"csv lookup disabled")
            return

        new_isbn = self.draft_vars["isbn"].get()
        
        """Triggered when ISBN changes. Looks up book details if ISBN is 13 digits."""
        if not isinstance(new_isbn, str) or len(new_isbn) != 13 or not new_isbn.isdigit():
            logging.debug(f"Invalid ISBN '{new_isbn}': must be 13 digits.")
            self.draft.reset()
            return

        logging.info(f"Looking up data for {new_isbn}")

        row = self.config.books.get(new_isbn, {})  # Fast lookup from cached dictionary

        if not row:
            logging.warning(f"No data found for {new_isbn}")
            self.draft_vars["sku"].set("")
            self.draft_vars["title"].set("")
            self.draft_vars["author"].set("")
            self.draft_vars["file_count_expected"].set(0)
            return

        logging.debug(f"Data found for {new_isbn} {row}")


        self.draft_vars["sku"].set(row.get('SKU', ""))
        self.draft_vars["title"].set(row.get('Title', ""))
        self.draft_vars["author"].set(row.get('Author', ""))
        self.draft_vars["file_count_expected"].set(row.get('ExpectedFileCount', 0))

    def load_isbn_csv_and_create_masters(self):
        csv_path = filedialog.askopenfilename(filetypes=[("CSV Files", "*.csv")], title="Select ISBN CSV File")
        if not csv_path:
            return

        input_folder = self.draft_vars["input_folder"].get()
        if not os.path.isdir(input_folder):
            messagebox.showerror("Error", "Invalid input folder.")
            return

        self.lookup_csv_var.set(True)
        self.ui_state["find_isbn_folder"].set(True)

        success, failed = [], []

        try:
            with open(csv_path, newline='', encoding='utf-8') as csvfile:
                reader = csv.reader(csvfile)
                for row in reader:
                    if not row or not row[0].strip():
                        continue

                    isbn = row[0].strip()
                    self.reset()
                    self.draft_vars["isbn"].set(isbn)

                    try:
                        folder_path = self.get_input_folder()
                        if not folder_path:
                            logging.info(f"Skipping ISBN {isbn} - folder not found.")
                            failed.append((isbn, "Folder not found"))
                            continue
                    except Exception as e:
                        logging.info(f"Skipping ISBN {isbn}: error {e}")
                        failed.append((isbn, str(e)))
                        continue

                    try:
                        self.create()
                        logging.info(f"Created master for ISBN {isbn}")
                        success.append(isbn)
                    except Exception as e:
                        logging.error(f"Error creating master for {isbn}: {e}")
                        failed.append((isbn, str(e)))


        except Exception as e:
            messagebox.showerror("Error", f"Failed to open CSV: {e}")
            return

        if failed:
            logging.warning("Some ISBNs failed to process:")
            for isbn, reason in failed:
                logging.warning(f"  - ISBN {isbn}: {reason}")

        logging.info(f"Batch Processing Summary: {len(success)} masters created. {len(failed)} failed.")









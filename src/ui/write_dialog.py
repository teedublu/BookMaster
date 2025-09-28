# ui/write_dialog.py
import tkinter as tk
from tkinter import ttk, messagebox

class WriteDialog(tk.Toplevel):
    def __init__(self, parent, usb_drive, image_path):
        super().__init__(parent)
        self.title("Writing image…")
        self.resizable(False, False)

        self.var = tk.IntVar(value=0)
        ttk.Label(self, text=f"Writing {image_path.name} to {usb_drive.device_path}").pack(padx=12, pady=(12,6))
        self.pb = ttk.Progressbar(self, orient="horizontal", mode="determinate", maximum=100, variable=self.var, length=360)
        self.pb.pack(padx=12, pady=6)
        self.btn_frame = ttk.Frame(self)
        self.btn_frame.pack(fill="x", padx=12, pady=(6,12))
        self.cancel_btn = ttk.Button(self.btn_frame, text="Cancel", command=self._cancel)
        self.cancel_btn.pack(side="right")

        def on_progress(pct):
            self.var.set(pct)

        def on_done(ok, err):
            if ok:
                messagebox.showinfo("Done", "Disk image written successfully.")
            else:
                messagebox.showerror("Error", err or "Write failed.")
            self.destroy()

        # Start async task
        self.task = usb_drive.write_disk_image_async(
            image_path=image_path,
            ui_parent=self,
            on_progress=on_progress,
            on_done=on_done,
            use_sudo=True,
        )

    def _cancel(self):
        if self.task:
            self.task.cancel()
        self.destroy()

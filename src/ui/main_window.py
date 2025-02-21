
import tkinter as tk
from tkinter import ttk, messagebox, filedialog
from PIL import Image, ImageTk
import os

class MainWindow:
    def __init__(self, root):
        self.root = root
        self.root.title("Audiobook Manager")
        self.root.geometry("600x400")

        # Main frame
        self.main_frame = ttk.Frame(self.root, padding="10")
        self.main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))

        # Title
        ttk.Label(self.main_frame, text="Audiobook Manager", font=('Helvetica', 16, 'bold')).grid(row=0, column=0, columnspan=2, pady=10)

        # Buttons
        ttk.Button(self.main_frame, text="Add Audiobook", command=self.add_audiobook).grid(row=1, column=0, pady=5, padx=5)
        ttk.Button(self.main_frame, text="View Audiobooks", command=self.view_audiobooks).grid(row=1, column=1, pady=5, padx=5)
        ttk.Button(self.main_frame, text="Process Files", command=self.process_files).grid(row=2, column=0, pady=5, padx=5)
        ttk.Button(self.main_frame, text="Validate Data", command=self.validate_data).grid(row=2, column=1, pady=5, padx=5)
        ttk.Button(self.main_frame, text="Load Image", command=self.load_image).grid(row=3, column=0, columnspan=2, pady=5, padx=5)
        
        # Image display area
        self.image_label = ttk.Label(self.main_frame)
        self.image_label.grid(row=4, column=0, columnspan=2, pady=10)
        
    def load_image(self):
        samples_dir = os.path.join(os.getcwd(), 'samples', 'images')
        file_path = filedialog.askopenfilename(
            initialdir=samples_dir,
            title="Select Image",
            filetypes=[("Image files", "*.jpg *.jpeg *.png *.gif *.bmp *.img")]
        )
        
        if file_path:
            try:
                image = Image.open(file_path)
                # Resize image to fit window while maintaining aspect ratio
                display_size = (400, 300)
                image.thumbnail(display_size, Image.Resampling.LANCZOS)
                photo = ImageTk.PhotoImage(image)
                
                self.image_label.configure(image=photo)
                self.image_label.image = photo  # Keep a reference
                messagebox.showinfo("Success", "Image loaded successfully")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to load image: {str(e)}")

    def add_audiobook(self):
        messagebox.showinfo("Info", "Add Audiobook functionality will be implemented here")

    def view_audiobooks(self):
        messagebox.showinfo("Info", "View Audiobooks functionality will be implemented here")

    def process_files(self):
        messagebox.showinfo("Info", "Process Files functionality will be implemented here")

    def validate_data(self):
        messagebox.showinfo("Info", "Validate Data functionality will be implemented here")

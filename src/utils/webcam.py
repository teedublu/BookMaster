import cv2
from threading import Thread
from PIL import Image, ImageTk
from pyzbar.pyzbar import decode
import numpy as np
import time

class Webcam:
    def __init__(self, video_label, callback):
        self.video_label = video_label
        self.callback = callback
        self.cap = None
        self.running = False
        self.thread = None
        self.img_tk = None  # Store the current image to avoid Tkinter resizing issues

        # Set a fixed size for the video label
        self.fixed_width = 320
        self.fixed_height = 240
        self.video_label.config(width=self.fixed_width, height=self.fixed_height)

        # Load a generic image to use when webcam is off
        generic_img_raw = Image.new('RGB', (self.fixed_width, self.fixed_height), color='gray')
        generic_img_raw.thumbnail((self.fixed_width, self.fixed_height), Image.LANCZOS)
        self.generic_img = ImageTk.PhotoImage(generic_img_raw)
        self.video_label.config(image=self.generic_img)

    def start(self):
        if not self.running:
            self.cap = cv2.VideoCapture(0)
            if not self.cap.isOpened():
                print("Error: Could not open webcam.")
                self.cap.release()
                self.cap = None
                return
            self.running = True
            self.thread = Thread(target=self._update_frame, daemon=True)
            self.thread.start()

    def stop(self):
        if self.running:

            self.running = False
            self.img_tk = self.generic_img
            self.video_label.config(image=self.img_tk)
            self.video_label.image = self.img_tk
            if self.thread:
                self.thread.join(timeout=2)  # Added timeout to prevent hanging
            if self.cap:
                time.sleep(0.5)  # Added delay to ensure resources are released properly
                self.cap.release()

                self.cap = None
             
    def _update_frame(self):
        while self.running:
            ret, frame = self.cap.read()
            if not ret:
                continue

            # Barcode detection using pyzbar
            barcodes = decode(frame)
            if barcodes:
                barcode_data = barcodes[0].data.decode('utf-8')
                if len(barcode_data) == 13 and barcode_data.isdigit():
                    print (barcode_data)
                    self.callback(barcode_data)
                #self.stop()  # Stop after detecting first barcode (optional)

            # Draw rectangles around detected barcodes
            for barcode in barcodes:
                points = barcode.polygon
                if len(points) > 4:
                    hull = cv2.convexHull(np.array(points, dtype=np.float32))
                    points = hull
                points = np.array(points, dtype=np.int32).reshape((-1, 1, 2))
                for j in range(len(points)):
                    cv2.line(frame, tuple(points[j][0]), tuple(points[(j+1) % len(points)][0]), (0, 255, 0), 3)

            # Convert frame to ImageTk for Tkinter
            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            img = Image.fromarray(frame)

            # Scale the image to fit the fixed label size while maintaining the aspect ratio
            img.thumbnail((self.fixed_width, self.fixed_height), Image.LANCZOS)

            self.img_tk = ImageTk.PhotoImage(image=img)
            self.video_label.config(image=self.img_tk)
            self.video_label.image = self.img_tk

    def release(self):
        if self.cap:
            self.cap.release()
            self.cap = None

    def __del__(self):
        self.release()

# Assuming toggle functionality is handled outside of this class
webcam = None

def toggle_webcam(video_label, isbn, use_webcam):
    global webcam
    if not webcam:
        webcam = Webcam(video_label, isbn)
    if use_webcam:
        webcam.start()
    else:
        webcam.stop()

import os
import re
import logging
import shutil
import subprocess
import tempfile
import time


class DiskImage:
    """
    Handles the creation of a disk image with the given source folder contents.
    """

    def __init__(self, output_base):
        self.output_base = output_base
        self.image_binaries_dir = os.path.join(self.output_base, "image_binaries")
        self.logger = logging.getLogger(__name__)
        os.makedirs(self.image_binaries_dir, exist_ok=True)

    def create_disk_image(self, master_root, sku):
        """
        Creates a disk image containing the contents of master_folder with SKU as its volume label.
        """
        if not master_root:
            logging.errpr(f"Error creating disk image from {master_root}")
            raise RuntimeError(f"Error creating disk image from {master_root}")

        master_folder = master_root

        # **Ensure the directory exists**
        try:
            master_folder.mkdir(parents=True, exist_ok=True)
            self.logger.info(f"Ensured master folder exists: {master_folder}")
        except Exception as e:
            self.logger.error(f"Failed to create master folder {master_folder}: {e}")
            raise

        logging.info(f"Creating disk image from {master_folder} in {self.output_base}")

        image_name = f"{sku}.img"
        image_path = os.path.join(self.image_binaries_dir, image_name)

        # Calculate the required image size
        source_size = int(subprocess.check_output(['du', '-sk', master_folder]).split()[0])
        image_size_mb = self.calculate_image_size(source_size)

        logging.info(f"Size {source_size} KB.")
        logging.info(f"Sector Count {image_size_mb * 2048}.")

        # Create the raw disk image
        self.create_raw_image(image_path, image_size_mb)

        # Attach the image and get the device path
        device = self.attach_image(image_path)

        # Format the disk as FAT32
        self.format_disk(device, sku, image_size_mb)

        # Mount the disk image and copy files
        self.mount_and_copy(device, master_folder)

        logging.info(f"Disk image saved in {image_path}.")
        return image_path

    def calculate_image_size(self, source_size):
        """Calculates the required disk image size with a 10% buffer."""
        image_size = source_size + source_size // 10  # Add 10% buffer
        image_size_mb = int(-(-image_size // 1024))  # Ceil division
        return max(image_size_mb, 5)  # Minimum size is 5MB

    def create_raw_image(self, image_path, image_size_mb):
        """Creates an empty raw disk image."""
        sector_count = (image_size_mb * 1024 * 1024) // 512
        logging.info(f"Creating empty raw image in {image_path} with {sector_count} sectors.")

        result = subprocess.run(["sudo", "dd", "if=/dev/zero", f"of={image_path}", "bs=512", f"count={sector_count}"],
                                capture_output=True)
        if result.returncode != 0:
            raise RuntimeError(f"Error creating raw disk image: {result.stderr.decode()}")

    def attach_image(self, image_path):
        """Attaches the disk image and returns the device path."""
        logging.info(f"Attaching image {image_path}.")
        device_output = subprocess.check_output(["hdiutil", "attach", "-nomount", image_path]).decode().strip().split()[-1]
        if not device_output.startswith("/dev/"):
            raise RuntimeError("Error: Failed to attach the disk image.")
        logging.info(f"Attached image as device {device_output}.")
        return device_output

    def format_disk(self, device, sku, image_size_mb):
        """Formats the disk image as FAT16 or FAT32 with the given SKU as the volume label."""
        volume_label = re.sub(r'[^A-Z0-9_]', '', sku.upper())[:11]
        fs_size = "16" if image_size_mb < 40 else "32"

        logging.info(f"Formatting {device} as FAT{fs_size} with label {volume_label}.")
        result = subprocess.run(["sudo", "newfs_msdos", "-F", fs_size, "-v", volume_label, device], capture_output=True)
        if result.returncode != 0:
            subprocess.run(["hdiutil", "detach", device])
            raise RuntimeError(f"Error formatting the disk image: {result.stderr.decode()}")

    def mount_and_copy(self, device, source_folder):
        """Mounts the disk image, copies files, then unmounts and detaches it."""
        mount_point = tempfile.mkdtemp()

        logging.info(f"Mounting {device} at {mount_point}.")
        result = subprocess.run(["sudo", "mount", "-t", "msdos", device, mount_point], capture_output=True)
        if result.returncode != 0:
            subprocess.run(["hdiutil", "detach", device])
            os.rmdir(mount_point)
            raise RuntimeError(f"Error mounting the disk image: {result.stderr.decode()}")

        logging.info(f"Copying files from {source_folder} to {mount_point}.")
        try:
            shutil.copytree(source_folder, mount_point, dirs_exist_ok=True)
        except Exception as e:
            self.cleanup(device, mount_point)
            raise RuntimeError(f"Error copying files to the disk image: {e}")

        self.cleanup(device, mount_point)


    def cleanup(self, device, mount_point):
        """Unmounts and detaches the disk image, then cleans up the mount point."""

        logging.info(f"Unmounting {mount_point}...")
        unmount_result = subprocess.run(["sudo", "umount", mount_point], capture_output=True)
        
        if unmount_result.returncode != 0:
            logging.warning(f"Unmount failed: {unmount_result.stderr.decode().strip()}")
            logging.info("Trying force unmount with diskutil...")
            subprocess.run(["diskutil", "unmountDisk", "force", device])

        time.sleep(1)  # Short delay to ensure unmount is processed

        logging.info(f"Detaching {device}...")
        detach_result = subprocess.run(["hdiutil", "detach", device], capture_output=True)

        if detach_result.returncode != 0:
            logging.warning(f"Detach failed: {detach_result.stderr.decode().strip()}")
            logging.info("Trying force detach...")
            subprocess.run(["hdiutil", "detach", "-force", device])

        time.sleep(1)  # Delay to prevent immediate re-mount

        # Cleanup mount point
        if os.path.exists(mount_point):
            os.rmdir(mount_point)

        logging.info(f"Unmounted and detached {device} successfully.")


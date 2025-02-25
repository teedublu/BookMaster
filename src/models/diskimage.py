import os
import subprocess
import logging
import shutil

class DiskImage:
    """
    Handles the creation of a FAT16/FAT32 disk image **without** mounting an actual disk.
    """

    def __init__(self, output_base):
        self.output_base = output_base
        self.image_binaries_dir = os.path.join(self.output_base, "image_binaries")
        self.logger = logging.getLogger(__name__)
        os.makedirs(self.image_binaries_dir, exist_ok=True)

    def create_disk_image(self, master_root, sku):
        """
        Creates a disk image containing the contents of master_root with SKU as its volume label.
        """
        if not master_root or not os.path.exists(master_root):
            self.logger.error(f"Error: Master root folder {master_root} does not exist.")
            raise RuntimeError(f"Error: Master root folder {master_root} does not exist.")

        image_name = f"{sku}.img"
        image_path = os.path.join(self.image_binaries_dir, image_name)

        # Calculate required image size
        source_size_kb = int(subprocess.check_output(["du", "-sk", master_root]).split()[0])
        image_size_mb = max((source_size_kb + source_size_kb // 10) // 1024, 10)  # +10% buffer, min 10MB

        self.logger.info(f"Creating {image_size_mb}MB disk image: {image_path}")

        # **1. Create a blank raw image file**
        sector_count = (image_size_mb * 1024 * 1024) // 512
        with open(image_path, "wb") as f:
            f.truncate(sector_count * 512)

        # **2. Format the image as FAT16/FAT32 using `mkfs.vfat`**
        self.format_disk_image(image_path, sku, image_size_mb)

        # **3. Copy files to the FAT filesystem without mounting**
        self.copy_files_to_image(image_path, master_root)

        self.logger.info(f"Disk image created successfully: {image_path}")
        return image_path

    def format_disk_image(self, image_path, volume_label, image_size_mb):
        """Formats the raw image file as FAT16/FAT32 using `mkfs.vfat`."""
        fs_type = "fat16" if image_size_mb < 40 else "fat32"
        self.logger.info(f"Formatting {image_path} as {fs_type.upper()} with label {volume_label}")

        result = subprocess.run(
            ["mkfs.vfat", "-F", "16" if fs_type == "fat16" else "32", "-n", volume_label, image_path],
            capture_output=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Error formatting disk image: {result.stderr.decode()}")

    def copy_files_to_image(self, image_path, source_folder):
        """Copies files into the disk image using `mcopy` from `mtools`."""

        if not shutil.which("mcopy"):
            raise RuntimeError("Error: `mtools` package is not installed. Install it using `brew install mtools`.")

        # Ensure source folder exists
        if not os.path.exists(source_folder):
            raise RuntimeError(f"Error: Source folder {source_folder} does not exist.")

        logging.info(f"Copying files from {source_folder} to {image_path}")

        # Ensure mtools image can be written to
        subprocess.run(["chmod", "u+w", image_path])

        # Copy `bookInfo` and `tracks` separately instead of using `*`
        for subfolder in ["bookInfo", "tracks"]:
            full_path = os.path.join(source_folder, subfolder)
            if os.path.exists(full_path):
                result = subprocess.run(
                    ["mcopy", "-i", image_path, "-s", full_path, "::"],
                    capture_output=True
                )

                if result.returncode != 0:
                    raise RuntimeError(f"Error copying {subfolder} to disk image: {result.stderr.decode()}")
            else:
                logging.warning(f"Skipping missing directory: {full_path}")

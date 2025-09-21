import os
import subprocess
import logging
import shutil
import fnmatch
from pathlib import Path
from utils import claim_unique_slot_and_log

class DiskImage:
    """
    Handles the creation of a FAT16/FAT32 disk image **without** mounting an actual disk.
    """

    def __init__(self, output_path):
        self.output_path = output_path
        self.logger = logging.getLogger(__name__)
        os.makedirs(self.output_path, exist_ok=True)

    def create_disk_image(self, master_root, sku):
        """
        Creates a disk image containing the contents of master_root with SKU as its volume label.
        """
        if not master_root or not os.path.exists(master_root):
            self.logger.error(f"Error: Master root folder {master_root} does not exist.")
            raise RuntimeError(f"Error: Master root folder {master_root} does not exist.")

        image_name = f"{sku}.img"
        image_path = os.path.join(self.output_path, image_name)

        # Calculate required image size
        source_size_kb = int(subprocess.check_output(["du", "-sk", master_root]).split()[0])
        buffer_kb = max(source_size_kb // 20, 5 * 1024)  # 5% or 5MB
        image_size_mb = max((source_size_kb + buffer_kb + 1023) // 1024, 10)  # round up using +1023, min 10MB total as FAT requires min 8MB

        self.logger.info(f"Creating {image_size_mb}MB disk image: {image_path}")

        # **1. Create a blank raw image file**
        sector_count = (image_size_mb * 1024 * 1024) // 512
        with open(image_path, "wb") as f:
            f.truncate(sector_count * 512)

        # **2. Format the image as FAT16/FAT32 using `mkfs.vfat`**
        self.format_disk_image(image_path, sku, image_size_mb)

        # **3. Copy files to the FAT filesystem without mounting**
        self.copy_files_to_image(image_path, master_root)

        # **4. Adjust to a unique size for tracking purposes **
        claim_unique_slot_and_log(image_path=image_path, sku=sku)

        # Log final disk image size
        final_size_bytes = os.path.getsize(image_path)
        final_size_mb = final_size_bytes / (1024 ** 2)
        self.logger.info(f"Disk image created successfully: {image_path} ({final_size_bytes:,} bytes / {final_size_mb:.2f} MB)")
        return image_path

    def format_disk_image(self, image_path, sku, image_size_mb):
        """Formats the raw image file as FAT16/FAT32 using `mkfs.vfat`."""
        volume_label = sku.replace("-", "").upper()[:11]

        fs_type = "fat16" if image_size_mb < 40 else "fat32"
        self.logger.info(f"Formatting {image_path} as {fs_type.upper()} with label {volume_label}")

        result = subprocess.run(
            ["mkfs.vfat", "-F", "16" if fs_type == "fat16" else "32", "-n", volume_label, image_path],
            capture_output=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Error formatting disk image: {result.stderr.decode()}")

    def copy_files_to_image(self, image_path, source_folder):
        """Copies files from `source_folder` to `image_path` FAT image using `mtools`."""
        patterns_to_ignore = [
            "._*", "*.DS_Store", ".fseventsd", ".Trashes", ".TemporaryItems", 
            ".Spotlight-V100", ".DocumentRevisions-V100", "System Volume Information", "*.tmp"
        ]

        def is_excluded(path):
            rel_path = str(path.relative_to(source_folder))
            return any(fnmatch.fnmatchcase(rel_path, pattern) or fnmatch.fnmatchcase(path.name, pattern) for pattern in patterns_to_ignore)


        source_folder = Path(source_folder)
        
        if not source_folder.exists():
            raise FileNotFoundError(f"Source folder {source_folder} does not exist.")

        # First, copy directories (since mcopy can't auto-create them)
        for folder in sorted(source_folder.glob("*/"), key=lambda p: str(p)):
            folder_rel = folder.relative_to(source_folder)
            logging.info(f"Creating directory in image: {folder_rel}")

            result = subprocess.run(
                ["mmd", "-i", image_path, f"::{folder_rel}"],
                capture_output=True
            )
            if result.returncode != 0 and "File exists" not in result.stderr.decode():
                raise RuntimeError(f"Error creating directory {folder_rel} in image: {result.stderr.decode()}")

        # Now copy files individually
        for file in sorted(source_folder.rglob("*")):
            if file.is_file() and not is_excluded(file):  # Ensure only files are copied
                file_rel = file.relative_to(source_folder)
                logging.info(f"Copying file to image: {file_rel}")

                result = subprocess.run(
                    ["mcopy", "-i", image_path, str(file), f"::{file_rel}"],
                    capture_output=True
                )

                if result.returncode != 0:
                    raise RuntimeError(f"Error copying {file_rel} to disk image: {result.stderr.decode()}")

        logging.info("File copy to image completed successfully.")


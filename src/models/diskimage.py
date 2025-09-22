import os
import subprocess
import logging
import shutil
import fnmatch, tempfile
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

    @staticmethod
    def _clear_readonly(path: str):
        # ignore errors on non-macOS
        subprocess.run(["chflags", "nouchg", path], check=False)
        subprocess.run(["chmod", "u+w", path], check=False)

    @staticmethod
    def _lock_readonly(path: str):
        subprocess.run(["chmod", "444", path], check=False)
        subprocess.run(["chflags", "uchg", path], check=False)

    def create_disk_image(self, master_root, sku):
        """
        Creates a disk image containing the contents of master_root with SKU as its volume label.
        """
        if not master_root or not os.path.exists(master_root):
            self.logger.error(f"Error: Master root folder {master_root} does not exist.")
            raise RuntimeError(f"Error: Master root folder {master_root} does not exist.")

        image_name = f"{sku}.img"
        image_path = os.path.join(self.output_path, image_name)


        # --- stage in a local temp dir (on fast local disk) ---
        with tempfile.TemporaryDirectory(prefix="bm_img_") as tmpdir:
            staging = Path(tmpdir) / image_name

            # 1) compute size, create blank raw image
            source_size_kb = int(subprocess.check_output(["du", "-sk", master_root]).split()[0])
            buffer_kb = max(source_size_kb // 20, 5 * 1024)  # 5% or 5MB
            image_size_mb = max((source_size_kb + buffer_kb + 1023) // 1024, 10) # round up using +1023, min 10MB total as FAT requires min 8MB

            self.logger.info(f"Creating {image_size_mb}MB disk image (staging): {staging}")
            sector_count = (image_size_mb * 1024 * 1024) // 512
            with open(staging, "wb") as f:
                f.truncate(sector_count * 512)

            # 2) format & copy into the STAGED image
            self.format_disk_image(str(staging), sku, image_size_mb)
            self.copy_files_to_image(str(staging), master_root)

            # 3) (optional) watermark + log to gsheet, operating on the STAGED image
            claim_unique_slot_and_log(image_path=str(staging), sku=sku)

            # 4) move into Google Drive target location atomically when possible
            self.logger.info(f"Publishing image to {image_path}")
            self._clear_readonly(str(staging))
            try:
                # Try atomic rename (same filesystem). If it fails, fallback to copy.
                os.replace(staging, image_path)
            except OSError:
                # cross-filesystem: copy then remove staged. Make sure staged is unlockable.
                shutil.copy2(staging, image_path)
                # Best-effort staged cleanup with retries in case a scanner briefly opens it
                for i in range(5):
                    try:
                        self._clear_readonly(str(staging))
                        os.remove(staging)
                        break
                    except PermissionError:
                        time.sleep(0.2 * (i+1))
                else:
                    self.logger.warning(f"Could not remove staging file (kept): {staging}")


        # 5) Done
        self._lock_readonly(str(image_path))
        final_size_bytes = os.path.getsize(image_path)
        final_size_mb = final_size_bytes / (1024 ** 2)
        self.final_size_mb = final_size_mb
        self.logger.info(f"Disk image created successfully: {image_path} ({final_size_bytes:,} bytes / {final_size_mb:.2f} MB)")
        return str(image_path)


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


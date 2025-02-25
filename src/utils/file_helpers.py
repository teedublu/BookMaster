import shutil
from pathlib import Path
import logging

def remove_folder(folder_path, settings, logger=None):
    """
    Safely removes a folder and its contents, ensuring it is within an allowed base directory.

    :param folder_path: Path to the folder to be deleted.
    :param settings: Settings object/dictionary containing "output_folder".
    :param logger: Optional logger for warnings and errors.
    :raises ValueError: If folder_path is outside the allowed base directory or is a critical system path.
    """

    folder_path = Path(folder_path).resolve()
    allowed_base = Path(settings.get("output_folder", "")).resolve()

    # Ensure the folder is within the allowed base directory
    if not folder_path.is_relative_to(allowed_base):
        raise ValueError(f"Refusing to delete {folder_path} - outside allowed base directory ({allowed_base})!")

    # Prevent deletion of critical system directories
    if str(folder_path) in ["/", "/home", "/Users", "/root", "/var", "/tmp"]:
        raise ValueError(f"Refusing to delete {folder_path} - critical system path detected!")

    # Log and delete only if the folder exists
    if folder_path.exists():
        if logger:
            logger.warning(f"Deleting folder: {folder_path}")
        shutil.rmtree(folder_path)
        if logger:
            logger.info(f"Successfully deleted: {folder_path}")

    # Recreate the directory
    folder_path.mkdir(parents=True, exist_ok=True)
    if logger:
        logger.info(f"Created clean folder: {folder_path}")

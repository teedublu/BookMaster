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



def find_input_folder_from_isbn(self, input_path, isbn):
    """
    Searches for a folder containing the given ISBN within the specified input path.

    Args:
        input_path (str | Path): The base directory to search in.
        isbn (str): The ISBN to look for in folder names.

    Returns:
        Path: The matching folder path.

    Raises:
        ValueError: If no matching folder is found.
    """
    # Ensure input_path is a Path object
    input_path = Path(input_path) if isinstance(input_path, str) else input_path

    logging.info(f"Looking for folder with {isbn} in name under {input_path}")

    # Check if input_path itself contains the ISBN
    if input_path.is_dir() and isbn in input_path.name:
        logging.info(f'{input_path} already contains ISBN {isbn}')
        return input_path

    # Search within subdirectories
    for subpath in input_path.iterdir():
        if subpath.is_dir() and isbn in subpath.name:
            logging.info(f'Found folder based on ISBN: {subpath}')
            return subpath

    # Raise an error if no folder is found
    raise ValueError(f"Folder with ISBN {isbn} not found under {input_path}.")

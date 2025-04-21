import shutil
from pathlib import Path
import logging
import hashlib
import subprocess
import random
import ffmpeg
import re, os
from mutagen.mp3 import MP3
from mutagen.id3 import ID3
from mutagen.wave import WAVE
import logging
from itertools import chain
from natsort import natsorted

EXCLUDED_DIRS = {".fseventsd", ".Spotlight-V100", ".Trashes", ".DS_Store"}


def probe_metadata(audio_file):
    """Uses ffmpeg-python to extract metadata from an audio file."""
    try:
        metadata = ffmpeg.probe(audio_file, select_streams='a', show_entries="format_tags")
        return metadata.get("format", {}).get("tags", {})
    except Exception as e:
        logging.error(f"Error probing metadata for {audio_file}: {e}")
        return {}

def get_metadata_from_audio(audio_file):
    """Extracts author and title metadata from MP3 and WAV files using ffmpeg-python for WAV."""
    try:
        if audio_file.lower().endswith(".mp3"):
            audio = MP3(audio_file, ID3=ID3)
            tags = audio.tags
            logging.debug(f"Getting tags from {audio_file}, {tags}")

            if tags:
                author = tags.get("TPE1", [""])[0]  # MP3: Performer/Author
                title = tags.get("TIT2", [""])[0]   # MP3: Track Title
                return author, title

        elif audio_file.lower().endswith(".wav"):
            tags = probe_metadata(audio_file)  # Use ffmpeg-python for WAV metadata
            logging.debug(f"Getting tags from {audio_file}, {tags}")

            if tags:
                author = tags.get("artist", "")  # WAV: Artist (Author)
                title = tags.get("title", "")   # WAV: Title
                logging.debug(f"Found tags {author}, {title}")
                return author, title

    except Exception as e:
        logging.error(f"Error reading metadata from {audio_file}: {e}")

    return None, None  # Return None if metadata is missing or invalid


def generate_isbn():
    return str(random.randint(1000000000000, 9999999999999))

def generate_sku(author, title, isbn):
    """Generates SKU in the format BK-XXXXX-ABCD where AB is from author, CD from title."""
    logging.debug(f"Creating sku from {author}, {title}, {isbn}")
    # Extract author initials (AB)
    author_abbr = "XX"
    if author:
        author_parts = author.split()
        if len(author_parts) > 1:
            author_abbr = author_parts[-1][:2].upper()  # Last name first two letters
        else:
            author_abbr = author_parts[0][:2].upper()  # Only one name

    # Extract title initials (CD)
    title_abbr = "YY"
    if title:
        words = re.findall(r"\b\w", title)  # Get first letter of each word
        if len(words) >= 2:
            title_abbr = (words[0] + words[1]).upper()  # First two letters from title
        elif words:
            title_abbr = (words[0] + "X").upper()  # Only one word, pad with X

    return f"BK-{isbn[-5:]}-{author_abbr}{title_abbr}"


def get_first_audiofile(input_folder, valid_formats=["*.mp3", "*.wav"]):
    """Returns the first valid audio file found in the given folder, or None if no valid files exist."""
    folder_path = Path(input_folder)

    if not folder_path.is_dir():
        raise ValueError(f"Invalid directory: {input_folder}")

    # Get all valid audio files and sort them naturally
    audio_files = sorted(chain.from_iterable(folder_path.glob(ext) for ext in valid_formats))

    logging.debug(f"Getting first file, found: {audio_files}")

    return str(audio_files[0]) if audio_files else None  # Return first audio file or None



def parse_time_to_minutes(time_str):
    """Convert HH:MM to total minutes as a float."""
    try:
        hours, minutes = map(float, time_str.split(":"))
        return hours * 60 + minutes  # Convert to total minutes
    except ValueError:
        logging.error(f"Invalid time format: {time_str}")
        return None

def compute_sha256(file_paths, base_path=None):
    """
    Computes a SHA-256 checksum for a list of files, incorporating both file contents and relative paths.

    :param file_paths: A list of Path objects representing files to include in the hash.
    :param base_path: Optional base path to compute relative paths from. Defaults to the common parent.
    :return: SHA-256 hash string or None if an error occurs.
    """
    hasher = hashlib.sha256()

    logging.debug(f"Creating hash for {len(file_paths)} paths")

    if not file_paths:
        return None

    # Establish base path for consistent relative path hashing
    if base_path is None:
        base_path = Path(os.path.commonpath([str(p) for p in file_paths]))

    for file_path in natsorted(file_paths, key=lambda p: str(p)):
        if file_path.is_file() and not any(part in EXCLUDED_DIRS for part in file_path.parts):
            try:
                # Include relative path in the hash
                rel_path = file_path.relative_to(base_path).as_posix()
                hasher.update(rel_path.encode('utf-8'))
                logging.debug(f"Hashing path: {rel_path}")

                # Include file content in the hash
                with file_path.open("rb") as f:
                    while chunk := f.read(8192):
                        hasher.update(chunk)

            except Exception as e:
                logging.error(f"Error processing {file_path}: {e}")
                return None

    return hasher.hexdigest()



def remove_system_files(drive):
    """
    Removes unwanted system files from the given drive.

    Args:
        drive (str or Path): The root directory of the drive.
    """
    drive_path = Path(drive)  # Ensure it's a Path object

    patterns_to_remove = [
        '._*', '*.DS_Store', '.fseventsd', '.Trashes', '.TemporaryItems', 
        '.Spotlight-V100', '.DocumentRevisions-V100', 'System Volume Information', '*.tmp'
    ]

    for pattern in patterns_to_remove:
        for file in drive_path.rglob(pattern):  # Recursively find matching files/folders
            try:
                if file.is_file() or file.is_symlink():
                    file.unlink()  # Remove file or symlink
                    logging.warning(f"Removed file: {file}")
                elif file.is_dir():
                    shutil.rmtree(file)  # Recursively remove directory
                    logging.warning(f"Removed directory: {file}")
            except Exception as e:
                logging.error(f"Failed to remove {file}: {e}")
                return False

    return True

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
        return str(input_path)

    # Search within subdirectories
    for subpath in input_path.iterdir():
        if subpath.is_dir() and isbn in subpath.name:
            logging.info(f'Found folder based on ISBN: {subpath}')
            return str(subpath)

    # Raise an error if no folder is found
    raise ValueError(f"Folder with ISBN {isbn} not found under {input_path}.")

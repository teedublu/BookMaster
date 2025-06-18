import mimetypes
import mutagen
import ffmpeg
from slugify import slugify
import shutil
from pathlib import Path
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TIT2, TPE1, TXXX
from .track import Track
import logging
from natsort import natsorted
from itertools import chain
import traceback

class Tracks:
    """
    Manages a collection of File objects and provides aggregate properties.
    """
    def __init__(self, master, directory, audio_params, tests=None):
        self.logger = logging.getLogger(__name__)
        self.directory = Path(directory).resolve()
        self.files = []
        self.master = master
        self.audio_params = audio_params  # Store the parameter object
        self.tests = tests

        self._load_files()
    
    def __str__(self):
        children = "\n".join(f'|-----{str(track)}' for track in self.files)
        return f"--{self.directory}\n{children}"

    def _load_files(self):
        """Loads all valid audio files from the directory and creates Track objects."""
        
        if not self.directory.exists() or not self.directory.is_dir():
            raise ValueError(f"Tracks directory missing or inaccessible: {self.directory}")

        logging.debug(f"Loading Tracks from {self.directory.parent.name}/{self.directory.name}")

        # Get valid extensions from config (e.g., ['.mp3', '.wav'])
        valid_extensions = self.master.settings.get("valid_extensions", ['.mp3', '.wav'])

        # Use multiple glob calls and merge results
        files = list(chain.from_iterable(self.directory.glob(f"*{ext}") for ext in valid_extensions))
        files = natsorted(files, key=lambda f: f.name)  # Sort naturally

        self.files = []

        for index, file in enumerate(files, start=1):
            try:
                track = Track(file, index, self.audio_params, self.tests, **{
                    "title": self.master.title,
                    "author": self.master.author,
                    "isbn": self.master.isbn,
                    "sku": self.master.sku
                })
                self.files.append(track)
            except Exception as e:
                logging.error(f"Failed to load Track {file.name}")
                logging.error(traceback.format_exc())

        if not self.files:
            raise ValueError(f"No valid tracks found in {self.directory}")

        logging.debug(f"Successfully loaded {self.master.title} {len(self.files)} Track(s) from {self.directory}")

    
    @property
    def duration(self):
        """ Returns the total duration of all files. """
        return sum(file.duration for file in self.files if file.duration)
    
    @property
    def count(self):
        """ Returns the count of all files. """
        return sum(1 for file in self.files)

    @property
    def total_size(self):
        """ Returns the total duration of all files. """
        return sum(file.file_size for file in self.files if file.duration)

    @property
    def total_size(self):
        """ Returns the total duration of all files. """
        return sum(file.size for file in self.files if file.size)

    @property
    def total_target_size(self):
        """ Returns the total duration of all files. """
        return sum(file.target_size for file in self.files if file.target_size)
    
    @property
    def all_valid(self):
        """ Returns True if the directory contains files that are not MP3 or system files. """
        return all(track.is_valid for track in self.files)

    @property
    def invalid_tracks(self):
        """ Returns a list of invalid tracks."""
        return [track for track in self.files if not track.is_valid]

    @property
    def has_silences(self):
        """ Returns True if the directory contains files that are not MP3 or system files. """
        return any(file.silences for file in self.files)
    
    @property
    def isbn(self):
        """ Returns the common ISBN if all files have the same, otherwise raises an error. """
        isbns = {file.isbn for file in self.files if file.isbn}
        if len(isbns) == 1:
            return isbns.pop()
        elif len(isbns) > 1:
            raise ValueError("Inconsistent ISBN values found in tracks.")
        return None
    
    @property
    def title(self):
        """ Returns the common title if all files have the same, otherwise raises an error. """
        titles = {file.title for file in self.files if file.title}
        if len(titles) == 1:
            return titles.pop()
        elif len(titles) > 1:
            raise ValueError("Inconsistent title values found in tracks.")
        return None
    
    @property
    def author(self):
        """ Returns the common author if all files have the same, otherwise raises an error. """
        authors = {file.author for file in self.files if file.author}
        if len(authors) == 1:
            return authors.pop()
        elif len(authors) > 1:
            raise ValueError("Inconsistent author values found in tracks.")
        return None

    def convert_all(self, destination_path, bit_rate):
        for track in natsorted(self.files, key=lambda t: t.file_path.name):
            track.convert(destination_path, bit_rate)
            self.logger.info(f"Encoding track: {track.file_path.parent.name}/{track.file_path.name} and moving to -> {destination_path.name}")


    def tag_all(self):
        for track in self.files:
            track.update_mp3_tags()
            self.logger.info(f"Tagging all tracks: {track.file_path.parent.name}/{track.file_path.name} ")
       

    def reencode_all_in_place(self):
        """
        Re-encodes all tracks in this Tracks instance using current encoding parameters,
        and overwrites each original file with the re-encoded version.
        """
        bit_rate = self.audio_params["encoding"]["bit_rate"]
        temp_dir = self.master.output_path / "_tmp_reencode"
        temp_dir.mkdir(exist_ok=True)

        logging.info(f"Re-encoding all tracks to temp dir: {temp_dir}")

        try:
            for track in self.files:
                temp_file = temp_dir / track.file_path.name
                track.convert(temp_dir, bit_rate)
                shutil.move(temp_file, track.file_path)
                logging.info(f"Re-encoded {track.file_path.name} to {bit_rate}bps and replaced original.")
        except Exception as e:
            logging.error(f"Failed during re-encoding: {e}")
        finally:
            # Clean up temp dir
            if temp_dir.exists():
                shutil.rmtree(temp_dir)


from pathlib import Path
import mimetypes
import mutagen
import ffmpeg
import slugify
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TIT2, TPE1, TXXX
from .track import Track
import logging
class Tracks:
    """
    Manages a collection of File objects and provides aggregate properties.
    """
    def __init__(self, master, directory, params, tests=None):
        
        self.directory = Path(directory).resolve()
        self.files = []
        self.master = master
        self.params = params  # Store the parameter object
        self.tests = tests

        self._load_files()
    
    def _load_files(self):
        logging.debug(f"Load Tracks with _load_files {self.directory}")
        """ Loads all audio files from the directory and creates File objects. """
        if self.directory.exists() and self.directory.is_dir():
            logging.debug(f"Load Track(s) from {self.directory}")

            self.files = [
                Track(self.master, file, index, self.params, self.tests)
                for index, file in enumerate(sorted(self.directory.glob("*.*"), key=lambda f: f.name), start=1)
                if not file.name.startswith(".")
            ]
            print ('-------------------------------')
            print (self.files)
        else:
            raise ValueError("Tracks directory missing or inaccessible.")
    
    @property
    def duration(self):
        """ Returns the total duration of all files. """
        return sum(file.duration for file in self.files if file.duration)
    
    @property
    def are_valid(self):
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

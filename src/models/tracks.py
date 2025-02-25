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
    def __init__(self, master, directory, params):
        
        self.directory = Path(directory).resolve()
        self.files = []
        self.master = master
        self.params = params  # Store the parameter object
        self._load_files()

        logging.debug(f"Init Tracks with {self.directory} with params {params}")
    
    def _load_files(self):
        """ Loads all audio files from the directory and creates File objects. """
        if self.directory.exists() and self.directory.is_dir():
            logging.debug(f"Load Track(s) from {self.directory} with params {self.params}")
            self.files = sorted(
                [
                    Track(self.master, file, index, self.params)
                    for index, file in enumerate(self.directory.glob("*.*"), start=1) 
                    if not file.name.startswith(".")
                ],
                key=lambda track: track.file_path.name
            )



        else:
            raise ValueError("Tracks directory missing or inaccessible.")
    
    @property
    def duration(self):
        """ Returns the total duration of all files. """
        return sum(file.duration for file in self.files if file.duration)
    
    @property
    def has_non_mp3_files(self):
        """ Returns True if the directory contains files that are not MP3 or system files. """
        return any(file.file_type != "mp3" for file in self.files)
    
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

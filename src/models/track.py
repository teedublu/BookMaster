from pathlib import Path
import mimetypes
import mutagen
import ffmpeg
import re
import sys
import base64
from slugify import slugify
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TIT2, TPE1, TXXX
from config.config import COLORS
import logging
import traceback

from utils.audio_helper import analyze_loudness, detect_silence, extract_metadata, check_frame_errors


class Track:
    """
    Represents a single audio file and its associated properties.
    """
    def __init__(self, master, file_path, file_index, params, tests):
        self.file_path = Path(file_path)
        self.file_size = self.file_path.stat().st_size
        self.file_type = self._determine_file_type()
        self.master = master
        self.audio = None
        self.track_name = None
        self.title = master.title
        self.author = master.author
        self.isbn = master.isbn
        self.sku = master.sku
        self.loudness = None
        self.index = file_index
        self.silences = []
        self.frame_errors = 0
        self.params = params  # Store the parameter object
        
        self.target_lufs = int(params["encoding"]["target_lufs"])
        self.sample_rate = int(params["encoding"]["sample_rate"])
        self.bit_rate = int(params["encoding"]["bit_rate"])  # bps
        self.channels = int(params["encoding"]["channels"])  # Mono = 1, Stereo = 2
        self.metadata = extract_metadata(self.file_path)
        self.tests = tests
        self.output_file = f"{str(self.index).zfill(3)}_{slugify(str(self.isbn)[-5:])}{slugify(str(self.sku)[-4:]).upper()}"[:13] + ".mp3"
        self.apply_tests()
        # if "convert" in self.tests:
        #     self.apply_metadata()
        #     self.apply_tests()
        #     self.convert(self.master.processed_path)
        # else:
        #     self.apply_tests()  # Perform all ffmpeg-related analysis first

        logging.debug(f"File index {file_index}, is called {file_path.parent.name}/{file_path.name} of type {self.file_type} metadata: {self.metadata}")


    def __str__(self):
        """
        Returns a colorized, user-friendly string representation of the track.
        Example:
            "track1.mp3" (Green for valid)
            "track2.mp3 (Silence)" (Yellow)
            "track3.mp3 (Frame errors)" (Red)
        """
        # Determine color based on status
        is_valid, issue_str = self.status
        color = COLORS["green"] if is_valid else COLORS["yellow"] if issue_str.startswith("Silence") else COLORS["red"]

        # Return formatted output
        issue_str_output = f" (issues: {', '.join(issue_str)})" if issue_str else ""
        return f"{color}{self.title} by {self.author} :{self.sku}_ {self.file_path.name} {self.sample_rate}k {self.bit_rate//1000}kbps {f' {issue_str_output}'}{COLORS['reset']}"



    def __repr__(self):
        """ Returns a detailed representation of the track for debugging. """
        return f"Track(filename={self.file_path.name}, is_valid={self.is_valid} , sample_rate={self.sample_rate}, bit_rate={self.bit_rate} frame_errors={self.frame_errors}, silences={len(self.silences)})"

    @property
    def duration(self):
        if not self.metadata:
            logging.warning(f"Requested duration but no metadata available for {self}")
            return None
        if not self.metadata.get("duration"):
            logging.warning(f"Requested duration but metadata does not contain duration for {self}")
            return None
        
        return self.metadata.get("duration")

    @property
    def title(self):
        """Safely returns the title from Master if available, otherwise falls back to metadata."""
        return getattr(self.master, "title", None) or (self.metadata or {}).get("title", "")

    @title.setter
    def title(self, value):
        """Sets the title in Master while ensuring it's properly updated."""
        self.master.title = value

    @property
    def author(self):
        """Safely returns the author from Master if available, otherwise falls back to metadata."""
        return getattr(self.master, "author", None) or (self.metadata or {}).get("author", "")

    @author.setter
    def author(self, value):
        """Sets the author in Master while ensuring it's properly updated."""
        self.master.author = value

    @property
    def status(self):
        """
        Returns a tuple:
        - First element: Boolean (True if valid, False if there are issues).
        - Second element: A detailed string with issues if any.
        """
        issues = []
        
        if self.silences:
            issues.append("Silence")
        if self.frame_errors > 0:
            issues.append(f"Frame errors: {self.frame_errors}")
        if not self.encoding_is_valid():
            issues.append("Encoding issue")

        issue_str = ", ".join(issues) if issues else None
        is_valid = not issues  # True if empty (no issues), False otherwise

        # logging.debug(f"issues={issues}, issue_str={issue_str}, is_valid={is_valid}")
        return is_valid, issue_str  # (True = valid, False = has issues)


    @property
    def is_valid(self):
        """ Returns True if the track has no issues. """
        return self.status[0]

    @property
    def encoded_size(self):
        """Estimates the encoded file size in MB based on bit rate and duration."""
        if not self.duration:
            return 0  # Avoid division errors if duration isn't set

        total_size_bytes = (self.bit_rate * self.duration) // 8  # Convert to bytes
        return total_size_bytes  # Convert to MB


    def encoding_is_valid(self):
        """ Checks if encoding parameters are correctly set. """
        return all([
            isinstance(self.sample_rate, int) and self.sample_rate > 0,
            isinstance(self.bit_rate, int) and self.bit_rate > 0,
            isinstance(self.channels, int) and self.channels in (1, 2)  # Mono or Stereo
        ])

    def loudness_is_valid(self):
        """ Checks if loudness is reported and within a reasonable range. """
        return self.loudness is not None and -40 < self.loudness < 0  # LUFS range for audio

    def _determine_file_type(self):
        """ Determines the file type based on its MIME type. """
        mime_type, _ = mimetypes.guess_type(self.file_path)
        return mime_type.split("/")[-1] if mime_type and "audio" in mime_type else None

    def apply_metadata(self):
        """ Applies extracted metadata to the Track object, ensuring safe value assignment.        """
        metadata = self.metadata
        # Extract values safely
        sample_rate = metadata.get("sample_rate")
        bit_rate = int(metadata["bit_rate"]) if "bit_rate" in metadata and metadata["bit_rate"] is not None else None
        channels = metadata.get("channels")
        duration = metadata.get("duration")
        album = metadata.get("album")
        title = metadata.get("title")

        # Set values, ensuring existing values aren't overridden with None
        # self.duration = duration if duration is not None else self.duration NOW set via @property
        self.bit_rate = min(filter(None, [bit_rate, self.bit_rate]), default=96000)
        self.sample_rate = min(filter(None, [sample_rate, self.sample_rate]), default=41000)
        self.channels = channels if channels is not None else self.channels

        # Assign album and title
        self.title = self.title or album
        self.track_name = self.track_name or title

        logging.debug(f"Metadata applied to Track giving {self}.")

    def apply_tests(self):
        """Runs only the specified audio tests."""
        test_list = self.tests.split(",") if isinstance(self.tests, str) else []
        tests = [t.lower().strip() for t in test_list]  # Convert to a list for reusability

        if not tests:
            logging.debug(f"No audio tests requested.")
            return

        logging.info(f"Performing audio tests {self.tests}. {"silence" in tests}")

        if "loudness" in tests:
            self.loudness = analyze_loudness(self.file_path)

        if ("silence" in tests):
            self.silences = detect_silence(self.file_path, self.params)

        if "frame_errors" in tests:
            self.frame_errors = check_frame_errors(self.file_path)

    def convert(self, destination_path, bit_rate):
        # takes input_file and converts into processed path
        if not self.duration:
            raise ValueError (f"Track missing duration {str(self)} can not convert")
        
        file_path = destination_path / self.output_file
        file_path_string = str(file_path)
        filter_complex = (
            f"[a0]volume=1.0[a1]; " # existing track
            f"anoisesrc=r=44100:c=pink:a=0.0001:d={self.duration}[a2]; " # pink noise track of duration = inoput track
            f"[a1][a2]amix=inputs=2:duration=first:dropout_transition=3[a3]; " # mix together with fade of pink at end
            f"[a3]loudnorm=I={self.target_lufs}:LRA=11:TP=-1.5[out]" # normalise loundness
        )
        # important to understand the full range of options available for loudnorm before applying widely
        # Full List of loudnorm Parameters in FFmpeg, use 2 pass?

        # this should trim overly long silence at start of track to prevent player seeming unreactive but cant get to work
        # f"[0:a]silenceremove=start_periods=1:start_duration=0.5:start_threshold=-50dB[a0]; "


        logging.info(f"Converting {self.file_path.parent.name}/{self.file_path.name} renaming to {file_path.parent.name}/{file_path.name} duration {self.duration} samplerate {self.sample_rate} bitrate {self.bit_rate} target_lufs {self.target_lufs}")
        try:
            (
                (
                    ffmpeg
                    .input(self.file_path)
                    .output(
                        file_path_string, 
                        ar=self.sample_rate, 
                        ab=f"{bit_rate//1000}k", 
                        ac=1, 
                        format='mp3', 
                        acodec='libmp3lame', 
                        filter_complex=filter_complex, 
                        map="[out]"
                    )
                    .run(quiet=True, overwrite_output=True)
                )
            )
        except ffmpeg.Error as e:
            logging.error(f"Error occurred while processing file: {self.file_path}")
            logging.error(e.stderr.decode('utf8'))
            raise e

        # although metatags can be written in ffmpeg, want to strip out all which this function does (ffmpeg seems to insist on encoder)
        
        # logging.info(f"Point Track to newly converted file {file_path.parent.name}/{file_path.name}")
        # self.file_path = Path(file_path_string)
        self.update_mp3_metadata()

    def update_mp3_metadata(self):
        logging.debug(f"Now clean all tags except the required ones for {self.title}, {self.author}")
        logging.debug(f"{self}")
        return
        self.audio = MP3(self.file_path, ID3=ID3)

        # Delete all existing ID3 tags
        self.audio.delete()

        # Add new tags
        audio["TALB"] = TALB(encoding=3, text=self.title)  # Album = Audiobook Title
        audio["TPE1"] = TPE1(encoding=3, text=self.author)  # Author
        audio["TIT2"] = TIT2(encoding=3, text=f"Track {self.file_index} from {self.title}")  # Track Name (e.g., "Chapter X")

        # Create a custom TXXX frame for the obfuscated ISBN
        obfuscated_isbn = base64.urlsafe_b64encode(str(self.isbn).encode()).decode()
        self.audio["TXXX:ID"] = TXXX(encoding=3, desc="ID", text=obfuscated_isbn)

        # Save the changes
        self.audio.save()
        logging.info(f"ID3 tags saved to {self.file_path.name} title:{self.title} author:{self.author} isbn:{self.isbn}")
        
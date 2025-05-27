from pathlib import Path
import mimetypes
import mutagen
import ffmpeg
import re
import sys
import base64
from slugify import slugify
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TALB, TPE1, TIT2, TXXX
from config.config import COLORS
import logging
import traceback

from utils.audio_helper import analyze_track, analyze_loudness, detect_silence, extract_metadata, check_frame_errors


class Track:
    """
    Represents a single audio file and its associated properties.
    """
    def __init__(self, file_path, file_index, params, tests, **kwargs):
        self.file_path = Path(file_path)
        self.file_size = self.file_path.stat().st_size
        self.file_type = self._determine_file_type()
        self.index = file_index
        self.params = params
        self.tests = tests

        # Optional metadata passed in via kwargs
        self.title = kwargs.get("title")
        self.author = kwargs.get("author")
        self.isbn = kwargs.get("isbn")
        self.sku = kwargs.get("sku")

        self.audio = None
        self.track_name = None
        
        self.target_lufs = int(params["encoding"]["target_lufs"])
        self.target_sample_rate = int(params["encoding"]["sample_rate"])
        self.target_bit_rate = int(params["encoding"]["bit_rate"])
        self.target_channels = int(params["encoding"]["channels"])

        self.output_file = f"{str(self.index).zfill(3)}_{slugify(str(self.isbn)[-5:])}{slugify(str(self.sku)[-4:]).upper()}"[:13] + ".mp3"

        self.track_analysis = analyze_track(self.file_path, self.params, self.tests)
        metadata = self.track_analysis.get("metadata", {})
        loudness = self.track_analysis.get("loudness", {})
        
        self.metadata = metadata
        self.duration = metadata.get("duration",0)
        self.sample_rate = metadata.get("sample_rate",None)
        self.bit_rate = metadata.get("bit_rate",None)
        self.channels = metadata.get("channels",None)
        self.tags = metadata.get("tags", {})

        self.loudness = loudness.get("input_i",None)
        self.silences = self.track_analysis.get("silences", [])
        self.frame_errors = self.track_analysis.get("frame_errors", 0)

        
        # if "convert" in self.tests:
        #     self.apply_metadata()
        #     self.apply_tests()
        #     self.convert(self.master.processed_path)
        # else:
        #     self.apply_tests()  # Perform all ffmpeg-related analysis first

        logging.debug(f"File index {file_index}, is called {file_path.parent.name}/{file_path.name} of type {self.file_type} metadata: {self.metadata} analysis:{self.track_analysis}")

    def __str__(self):
        
        # Determine color based on status
        is_valid, issue_str = self.status
        color = COLORS["green"] if is_valid else COLORS["yellow"] if issue_str.startswith("Silence") else COLORS["red"]

        title = self.title or "Unknown Title"
        author = self.author or "Unknown Author"
        sku = self.sku or "NO-SKU"
        name = self.file_path.name[:16] + "..." if self.file_path else "NOFILE"
        sample_rate = f"{self.sample_rate}k" if self.sample_rate else "??k"
        bitrate = f"{self.bit_rate // 1000}kbps" if self.bit_rate else "??kbps"
        issue_str_output = self.issue_str() if hasattr(self, "issue_str") else ""
        return f"{color}{title} by {author} :{sku}_ {name} {sample_rate} {bitrate} ({issue_str_output}){COLORS['reset']}"


    def __repr__(self):
        """ Returns a detailed representation of the track for debugging. """
        return f"Track(filename={self.file_path.name}, is_valid={self.is_valid} , sample_rate={self.sample_rate}, bit_rate={self.bit_rate} frame_errors={self.frame_errors}, silences={len(self.silences)})"

    @property
    def loudness_is_close_to_target(self):
        """
        Returns True if loudness is within ±10% of the target LUFS value.
        """
        if self.loudness is None:
            return True  # Can't evaluate, test not requested

        target_lufs = self.params.get("encoding", {}).get("target_lufs", -19)
        deviation = abs(self.loudness - target_lufs)
        allowed_deviation = abs(target_lufs) * 0.05

        return deviation <= allowed_deviation


    @property
    def status(self):
        """
        Returns a tuple:
        - First element: Boolean (True if valid, False if there are issues).
        - Second element: A detailed string with issues if any.
        """
        issues = []
        
        if self.silences:
            issues.append(f"Silence: {len(self.silences)}")
        if self.frame_errors and self.frame_errors > 0:
            issues.append(f"Frame errors: {self.frame_errors}")
        if not self.encoding_is_valid():
            issues.append(f"Encoding issue: {self.sample_rate}kbps {self.bit_rate}kHz {self.channels} channel  -{self.loudness}dB")
        if not self.loudness_is_close_to_target:
            issues.append(f"Loudness issue: {self.loudness} v  {self.target_lufs}")

        issue_str = ", ".join(issues) if issues else None
        is_valid = not issues  # True if empty (no issues), False otherwise

        # logging.debug(f"issues={issues}, issue_str={issue_str}, is_valid={is_valid}")
        return is_valid, issue_str  # (True = valid, False = has issues)

    @property
    def is_valid(self):
        """ Returns True if the track has no issues. """
        return self.status[0]

    @property
    def size(self):
        """Estimates the encoded file size in MB based on bit rate and duration."""
        if not self.duration:
            return 0  # Avoid division errors if duration isn't set

        total_size_bytes = (self.bit_rate * self.duration) // 8  # Convert to bytes
        return total_size_bytes

    @property
    def target_size(self):
        """Estimates the encoded file size in MB based on bit rate and duration."""
        if not self.duration:
            return 0  # Avoid division errors if duration isn't set

        total_size_bytes = (self.target_bit_rate * self.duration) // 8  # Convert to bytes
        return total_size_bytes


    def encoding_is_valid(self):
        """Checks if encoding parameters are valid. Includes loudness only if requested."""
        tests = self.tests
        checks = [
            isinstance(self.sample_rate, int) and self.sample_rate > 0,
            isinstance(self.bit_rate, int) and self.bit_rate > 0,
            isinstance(self.channels, int) and self.channels in (1,)
        ]

        if tests and "loudness" in [t.lower() for t in tests]:
            checks.append(isinstance(self.loudness, (int, float)) and -40 < self.loudness < 0)

        return all(checks)

    def _determine_file_type(self):
        """ Determines the file type based on its MIME type. """
        mime_type, _ = mimetypes.guess_type(self.file_path)
        return mime_type.split("/")[-1] if mime_type and "audio" in mime_type else None

    def convert(self, destination_path, bit_rate):
        # takes input_file and converts into processed path
        Path(destination_path).mkdir(parents=True, exist_ok=True)

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


        logging.info(f"Converting {self.file_path.parent.name}/{self.file_path.name} renaming to {file_path_string} duration {self.duration} samplerate {self.target_sample_rate} bitrate {bit_rate} target_lufs {self.target_lufs}")
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

        # self.update_mp3_tags()

    def update_mp3_tags(self):
        
        self.audio = MP3(self.file_path, ID3=ID3)

        # Delete all existing ID3 tags
        self.audio.delete()

        # Add new tags
        self.audio["TALB"] = TALB(encoding=3, text=self.title)  # Album = Audiobook Title
        self.audio["TPE1"] = TPE1(encoding=3, text=self.author)  # Author
        self.audio["TIT2"] = TIT2(encoding=3, text=f"Track {self.index} from {self.title}")  # Track Name (e.g., "Chapter X")

        # Create a custom TXXX frame for the obfuscated ISBN
        obfuscated_isbn = base64.urlsafe_b64encode(str(self.isbn).encode()).decode()
        self.audio["TXXX:ID"] = TXXX(encoding=3, desc="ID", text=obfuscated_isbn)

        # Save the changes
        self.audio.save()
        logging.info(f"ID3 tags saved to file {self.file_path} title:{self.title} author:{self.author} isbn:{self.isbn} {self.audio}")
        
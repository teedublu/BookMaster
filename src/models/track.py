from pathlib import Path
import mimetypes
import mutagen
import ffmpeg
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TIT2, TPE1, TXXX
import logging

class Track:
    """
    Represents a single audio file and its associated properties.
    """
    def __init__(self, file_path, params):
        logging.debug(f"Init Track from {file_path}")
        self.file_path = Path(file_path)
        self.file_type = self._determine_file_type()
        self.title = None
        self.author = None
        self.isbn = None
        self.duration = None
        self.loudness = None
        self.silences = []
        self.frame_errors = 0
        self.params = params  # Store the parameter object

        self._analyze_audio_properties()  # Perform all ffmpeg-related analysis first
        if self.file_type == "mp3":
            self._extract_metadata()  # Extract metadata after audio analysis
    
    @property
    def is_valid(self):
        """ Determines if the track is valid based on silence and frame errors. """
        return not self.silences and self.frame_errors == 0

    def _determine_file_type(self):
        """ Determines the file type based on its MIME type. """
        mime_type, _ = mimetypes.guess_type(self.file_path)
        return mime_type.split("/")[-1] if mime_type and "audio" in mime_type else None

    def _extract_metadata(self):
        """ Extracts metadata from MP3 files. """
        print(self.file_path)
        try:
            audio = MP3(self.file_path, ID3=ID3)
            tags = audio.tags
            if tags:
                self.title = tags.get("TIT2").text[0] if tags.get("TIT2") else None
                self.author = tags.get("TPE1").text[0] if tags.get("TPE1") else None
                self.isbn = tags.get("TXXX:isbn").text[0] if tags.get("TXXX:isbn") else None
        except Exception as e:
            print(f"Warning: Could not read metadata from {self.file_path}: {e}")

    def _analyze_audio_properties(self):
        """ Runs loudness and silence detection in one ffmpeg command and frame error check separately. """
        import re
        logging.debug("SKIPPING ANALYSE AUDIO IN TRACK")
        return
        try:
            silence_params = self.params.get("silence_detect", "silencedetect=noise=-30dB:d=0.5")
            loudnorm_params = self.params.get("loudnorm", "loudnorm=print_format=json")

            # Run loudness and silence detection together
            result = ffmpeg.input(str(self.file_path)) \
                .filter("silencedetect", noise=f"{self.params.get('silence_threshold', -30)}dB", d=self.params.get("min_silence_duration", 0.5)) \
                .output("null", f="null").global_args("-hide_banner").run(capture_stderr=True)

            output = result[1].decode("utf-8")  # Capture stderr instead of stdout
            print("FFmpeg Output:", output)  # Debugging step

            # Extract loudness safely
            if "input_i:" in output:
                try:
                    loudness_str = output.split("input_i:")[1].split("dB")[0].strip()
                    self.loudness = float(loudness_str) if loudness_str else None  # Handle missing values
                except ValueError:
                    self.loudness = None
                    print("Warning: Could not parse loudness value.")

            # Extract silence periods using regex
            self.silences = []
            silence_matches = re.findall(r"silence_start:\s*([\d\.]+)", output)

            for match in silence_matches:
                try:
                    self.silences.append(float(match))
                except ValueError:
                    print(f"Warning: Could not parse silence_start value: {match}")

            # Extract duration safely
            probe = ffmpeg.probe(str(self.file_path))
            if "format" in probe and "duration" in probe["format"]:
                try:
                    self.duration = float(probe["format"]["duration"])
                except ValueError:
                    self.duration = None
                    print("Warning: Could not parse audio duration.")

        except Exception as e:
            print(f"Warning: Could not analyze audio properties for {self.file_path}: {e}")

        # Run frame error check separately
        try:
            error_result = ffmpeg.input(str(self.file_path)).output("null", f="null").global_args("-hide_banner", "-loglevel", "error").run(capture_stderr=True)
            self.frame_errors = len(error_result[1].decode("utf-8").splitlines())
        except Exception as e:
            print(f"Warning: Could not check frame errors for {self.file_path}: {e}")

        logging.info(f"Analysed file {self.file_path}")



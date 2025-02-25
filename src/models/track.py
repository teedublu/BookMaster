from pathlib import Path
import mimetypes
import mutagen
import ffmpeg
import re
import base64
from slugify import slugify
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TIT2, TPE1, TXXX
import logging
import traceback

class Track:
    """
    Represents a single audio file and its associated properties.
    """
    def __init__(self, master, file_path, file_index, params):
        self.file_path = Path(file_path)
        self.file_type = self._determine_file_type()
        self.title = master.title
        self.author = master.author
        self.isbn = master.isbn
        self.sku = master.sku
        self.duration = None
        self.loudness = None
        self.index = file_index
        self.silences = []
        self.frame_errors = 0
        self.params = params  # Store the parameter object
        self.master = master
        self.target_lufs = int(params["encoding"]["target_lufs"])
        self.sample_rate = int(params["encoding"]["sample_rate"])
        self.bit_rate = int(params["encoding"]["bit_rate"])  # bps
        self.channels = int(params["encoding"]["channels"])  # Mono = 1, Stereo = 2

        self.output_file = f"{str(self.index).zfill(3)}_{slugify(self.isbn[-5:])}{slugify(self.sku[-4:]).upper()}"[:13] + ".mp3"


        self._analyze_audio_properties()  # Perform all ffmpeg-related analysis first
        if self.file_type == "mp3":
            self._extract_metadata()  # Extract metadata after audio analysis
    
    @property
    def is_valid(self):
        """ 
        Determines if the track is valid based on silence, frame errors, 
        and correct metadata reporting.
        """
        return (
            not self.silences and
            self.frame_errors == 0 and
            bool(self.isbn) and  # Ensure ISBN is present
            self.encoding_is_valid() and  # Validate encoding
            self.loudness_is_valid()  # Validate loudness
        )

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

    def _extract_metadata(self):
        """ Extracts metadata from MP3 files. """
        try:
            audio = MP3(self.file_path, ID3=ID3)
            tags = audio.tags
            if tags:
                self.title = tags.get("TIT2").text[0] if tags.get("TIT2") else None
                self.author = tags.get("TPE1").text[0] if tags.get("TPE1") else None
                self.isbn = tags.get("TXXX:isbn").text[0] if tags.get("TXXX:isbn") else None
        except Exception as e:
            logging.debug(f"Warning: Could not read metadata from {self.file_path}: {e}")

    def _analyze_audio_properties(self):
        """ Runs loudness and silence detection in one ffmpeg command and frame error check separately. """
        
        result = ffmpeg.input(str(self.file_path)) \
            .filter("silencedetect", noise=f"{self.params.get('silence_threshold', -30)}dB", d=self.params.get("min_silence_duration", 0.5)) \
            .output("null", f="null").global_args("-hide_banner").run(capture_stderr=True)

        try:
            # Run loudness and silence detection together
            result = ffmpeg.input(str(self.file_path)) \
                .filter("silencedetect", noise=f"{self.params.get('silence_threshold', -30)}dB", d=self.params.get("min_silence_duration", 0.5)) \
                .output("null", f="null").global_args("-hide_banner").run(capture_stderr=True)

            output = result[1].decode("utf-8")  # Capture stderr instead of stdout
            logging.debug(f"FFmpeg Output: {result}")  # Debugging step            

            # Extract loudness safely
            if "input_i:" in output:
                try:
                    loudness_str = output.split("input_i:")[1].split("dB")[0].strip()
                    self.loudness = float(loudness_str) if loudness_str else None  # Handle missing values
                except ValueError:
                    self.loudness = None
                    logging.debug("Warning: Could not parse loudness value.")

            # Extract silence periods using regex
            self.silences = []
            silence_matches = re.findall(r"silence_start:\s*([\d\.]+)", output)

            for match in silence_matches:
                try:
                    self.silences.append(float(match))
                except ValueError:
                    logging.debug(f"Warning: Could not parse silence_start value: {match}")

            # Extract duration safely
            probe = ffmpeg.probe(str(self.file_path))
            if "format" in probe and "duration" in probe["format"]:
                try:
                    # self.duration = float(probe["format"]["duration"])
                    self.duration = float(probe.get("format").get("duration", "0"))
                except ValueError:
                    self.duration = None
                    logging.warning("Warning: Could not parse audio duration.")

            audio_stream = next((s for s in probe["streams"] if s["codec_type"] == "audio"), None)
            if audio_stream:
                sample_rate = int(audio_stream.get("sample_rate", 0))
                bit_rate = int(audio_stream.get("bit_rate", 0))
                self.channels = int(audio_stream.get("channels", 0))  # Mono = 1, Stereo = 2
                self.bit_rate = int(min(bit_rate, self.bit_rate))
                self.sample_rate = int(min(sample_rate, self.sample_rate))

        except Exception as e:
            tb = traceback.extract_tb(e.__traceback__)[-1]  # Get the last traceback entry
            logging.debug(f"Warning: Could not check frame errors for {self.file_path} at {tb.filename}:{tb.lineno}: {e}")

        # Run frame error check separately
        try:
            error_result = ffmpeg.input(str(self.file_path)).output("null", f="null").global_args("-hide_banner", "-loglevel", "error").run(capture_stderr=True)
            self.frame_errors = len(error_result[1].decode("utf-8").splitlines())
        except Exception as e:
            logging.debug(f"Warning: Could not check frame errors for {self.file_path}: {e}")

        logging.info(f"Analysed file {self.file_path}")

    def convert(self, destination_path):
        # props = self._analyze_audio_properties()
        # if not props:
        #     logging.warning(f"Skipping {self.file_path.name}, unable to retrieve audio properties.")
            
        file_path_string = str(destination_path / self.output_file)


        filter_complex = (
            f"[a0]volume=1.0[a1]; " # existing track
            f"anoisesrc=r=44100:c=pink:a=0.0001:d={self.duration}[a2]; " # pink noise track of duration = inoput track
            f"[a1][a2]amix=inputs=2:duration=first:dropout_transition=3[a3]; " # mis together with fade of pink at end
            f"[a3]loudnorm=I={self.target_lufs}:LRA=11:TP=-1.5[out]" # normalise loundness
        )
        # important to understand the full range of options available for loudnorm before applying widely
        # Full List of loudnorm Parameters in FFmpeg, use 2 pass?

        # this should trim overly long silence at start of track to prevent player seeming unreactive but cant get to work
        # f"[0:a]silenceremove=start_periods=1:start_duration=0.5:start_threshold=-50dB[a0]; "


        logging.info(f"Converting {self.file_path.name} renaming to {file_path_string} duration {self.duration} samplerate {self.sample_rate} bitrate {self.bit_rate}")
        try:
            (
                (
                    ffmpeg
                    .input(self.file_path)
                    .output(
                        file_path_string, 
                        ar=self.sample_rate, 
                        ab=f"{self.bit_rate}k", 
                        ac=1, 
                        format='mp3', 
                        acodec='libmp3lame', 
                        filter_complex=filter_complex, 
                        map="[out]",
                        map_metadata="-1"
                    )
                    .run(quiet=True, overwrite_output=True)
                )
            )
        except ffmpeg.Error as e:
            logging.error(f"Error occurred while processing file: {self.file_path}")
            logging.error(e.stderr.decode('utf8'))
            raise e

        # although metatags can be written in ffmpeg, want to strip out all which this function does (ffmpeg seems to insist on encoder)
        self.update_mp3_metadata(self.file_path, self.title, self.author, self.isbn)

    def update_mp3_metadata(self, file_path, title, author, isbn):
        """
        Remove all existing ID3 tags from an MP3 file and set new metadata.

        Parameters:
        - file_path: Path to the MP3 file.
        - title: Title of the track.
        - author: Author/Artist of the track.
        - isbn: ISBN number to be obfuscated and added as a custom tag.
        """
        # Load the MP3 file
        audio = MP3(file_path, ID3=ID3)

        # Delete all existing ID3 tags
        audio.delete()

        # Add new tags
        audio["TIT2"] = TIT2(encoding=3, text=title)  # Title tag
        audio["TPE1"] = TPE1(encoding=3, text=author)  # Artist/Author tag

        # Create a custom TXXX frame for the obfuscated ISBN
        obfuscated_isbn = base64.urlsafe_b64encode(str(isbn).encode()).decode()
        audio["TXXX:ID"] = TXXX(encoding=3, desc="ID", text=obfuscated_isbn)

        # Save the changes
        audio.save()
        logging.info(f"ID3 tags saved to {file_path.name}")
        
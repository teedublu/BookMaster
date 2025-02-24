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
        self.target_lufs = params["encoding"]["target_lufs"]
        self.sample_rate = params["encoding"]["sample_rate"]
        self.bit_rate = params["encoding"]["bit_rate"]  # bps
        self.channels = params["encoding"]["channels"]  # Mono = 1, Stereo = 2

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
                    self.duration = float(probe["format"]["duration"])
                except ValueError:
                    self.duration = None
                    logging.warning("Warning: Could not parse audio duration.")

            audio_stream = next((s for s in probe["streams"] if s["codec_type"] == "audio"), None)
            if audio_stream:
                sample_rate = int(audio_stream.get("sample_rate", 0))
                bit_rate = int(audio_stream.get("bit_rate", 0))
                self.channels = int(audio_stream.get("channels", 0))  # Mono = 1, Stereo = 2
                self.bit_rate = f"{min(bit_rate, self.params["encoding"]["bit_rate"]) // 1000}k"
                self.sample_rate = min(sample_rate, self.params["encoding"]["sample_rate"])

        except Exception as e:
            logging.warning(f"Could not analyze audio properties for {self.file_path}: {e}")

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
            

        new_file_name = f"{str(self.index).zfill(3)}_{slugify(self.isbn[-5:])}{slugify(self.sku[-4:]).upper()}"[:13] + ".mp3"
        file_path_string = str(destination_path / new_file_name)

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

        # add metadata
        metadata = {
            'metadata:g:0': "title="+ self.title,
            'metadata:g:1': "artist="+ self.author,
            'metadata:g:2': "TXXX=ID:"+ base64.urlsafe_b64encode(str(self.isbn).encode()).decode(), #obfuscate
            'metadata:g:3': "encoder=" # explcitly remove the encoder tag that gets set
        }

        # logging.info(f"converting {file.name} {sample_rate_icon} renaming to {new_file_name} duration {duration} metadata {metadata} samplerate {final_sample_rate} bitrate {final_bitrate}")
        try:
            (
                (
                    ffmpeg
                    .input(self.file_path)
                    .output(
                        file_path_string, 
                        ar=self.sample_rate, 
                        ab=self.bit_rate, 
                        ac=1, 
                        format='mp3', 
                        acodec='libmp3lame', 
                        filter_complex=filter_complex, 
                        map="[out]",
                        map_metadata="-1",
                        write_xing=0,
                        **metadata
                    )
                    .run(quiet=True, overwrite_output=True)
                )
            )
        except ffmpeg.Error as e:
            logging.error(f"Error occurred while processing file: {self.file_path}")
            logging.error(e.stderr.decode('utf8'))
            raise e

        # although metatags written in ffmpeg, want to strip out all which this function does (ffmpeg seems to insist on encoder)
        
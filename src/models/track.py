class Track:
    """
    Represents a single audio file and its associated properties.
    """
    def __init__(self, file_path, params):
        self.file_path = Path(file_path)
        self.file_type = self._determine_file_type()
        self.title = None
        self.author = None
        self.isbn = None
        self.duration = None
        self.loudness = None
        self.silences = None
        self.frame_errors = None
        self.params = params  # Store the parameter object
        
        self._analyze_audio_properties()  # Perform all ffmpeg-related analysis first
        if self.file_type == "mp3":
            self._extract_metadata()  # Extract metadata after audio analysis
    
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
            print(f"Warning: Could not read metadata from {self.file_path}: {e}")
    
    def _analyze_audio_properties(self):
        """ Runs loudness and silence detection in one ffmpeg command and frame error check separately. """
        try:
            silence_params = self.params.get("silence_detect", "silencedetect=noise=-30dB:d=0.5")
            loudnorm_params = self.params.get("loudnorm", "loudnorm=print_format=json")
            
            # Run loudness and silence detection together
            result = ffmpeg.input(str(self.file_path)).filter("silencedetect", noise=f"{self.params.get('silence_threshold', -30)}dB", d=self.params.get("min_silence_duration", 0.5)) \
                .output("null", f="null").global_args("-hide_banner").run(capture_stderr=True)
            
            output = result[0].decode("utf-8")
            
            if "input_i:" in output:
                self.loudness = float(output.split("input_i:")[1].split("dB")[0].strip())
            
            self.silences = [float(line.split("silence_start:")[1].split(" ")[0]) 
                             for line in output.splitlines() if "silence_start:" in line]
            
            # Extract duration from ffmpeg probe
            probe = ffmpeg.probe(str(self.file_path))
            self.duration = float(probe["format"]["duration"])
        except Exception as e:
            print(f"Warning: Could not analyze audio properties for {self.file_path}: {e}")
        
        # Run frame error check separately
        try:
            error_result = ffmpeg.input(str(self.file_path)).output("null", f="null").global_args("-hide_banner", "-loglevel", "error").run(capture_stderr=True)
            self.frame_errors = len(error_result[1].decode("utf-8").splitlines())
        except Exception as e:
            print(f"Warning: Could not check frame errors for {self.file_path}: {e}")


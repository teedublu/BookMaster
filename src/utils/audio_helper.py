import ffmpeg
import logging
import re
import traceback

def analyze_loudness(file_path):
    """
    Analyzes loudness levels using FFmpeg.

    Args:
        file_path (Path): Path to the audio file.

    Returns:
        float: Integrated loudness in LUFS, or None if not detected.
    """
    try:
        result = ffmpeg.input(str(file_path)) \
            .output("null", f="null") \
            .global_args("-hide_banner") \
            .run(capture_stderr=True)

        output = result[1].decode("utf-8")  # Capture stderr where FFmpeg logs output
        logging.debug(f"FFmpeg Output (Loudness): {output}")

        # Extract loudness using regex
        if "input_i:" in output:
            try:
                loudness_str = output.split("input_i:")[1].split("dB")[0].strip()
                return float(loudness_str) if loudness_str else None
            except ValueError:
                logging.debug("Warning: Could not parse loudness value.")

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.debug(f"Warning: Could not analyze loudness for {file_path} at {tb.filename}:{tb.lineno}: {e}")

    return None

def detect_silence(file_path, params):
    """
    Detects silence in an audio file using FFmpeg.

    Args:
        file_path (Path): Path to the audio file.
        params (dict): Dictionary containing processing parameters.

    Returns:
        list: List of silence start times (float), or an empty list if no silence detected.
    """
    try:
        result = ffmpeg.input(str(file_path)) \
            .filter("silencedetect", noise=f"{params.get('silence_threshold', -30)}dB", 
                    d=params.get("min_silence_duration", 0.5)) \
            .output("null", f="null").global_args("-hide_banner") \
            .run(capture_stderr=True)

        output = result[1].decode("utf-8")
        logging.debug(f"FFmpeg Output (Silence Detection): {output}")

        # Extract silence periods using regex
        silence_matches = re.findall(r"silence_start:\s*([\d\.]+)", output)
        return [float(match) for match in silence_matches]

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.debug(f"Warning: Could not analyze silence for {file_path} at {tb.filename}:{tb.lineno}: {e}")

    return []

def extract_audio_metadata(file_path):
    """
    Extracts audio metadata including duration, sample rate, bit rate, and channels.

    Args:
        file_path (Path): Path to the audio file.

    Returns:
        dict: Contains duration (float), sample_rate (int), bit_rate (int), and channels (int).
    """
    results = {
        "duration": None,
        "sample_rate": None,
        "bit_rate": None,
        "channels": None
    }

    try:
        probe = ffmpeg.probe(str(file_path))
        if "format" in probe and "duration" in probe["format"]:
            try:
                results["duration"] = float(probe["format"]["duration"])
            except ValueError:
                logging.warning("Warning: Could not parse audio duration.")

        audio_stream = next((s for s in probe["streams"] if s["codec_type"] == "audio"), None)
        if audio_stream:
            results["sample_rate"] = int(audio_stream.get("sample_rate", 0))
            results["bit_rate"] = int(audio_stream.get("bit_rate", 0))
            results["channels"] = int(audio_stream.get("channels", 0))

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.debug(f"Warning: Could not extract metadata for {file_path} at {tb.filename}:{tb.lineno}: {e}")

    return results

def check_frame_errors(file_path):
    """
    Checks for frame errors in an audio file using FFmpeg.

    Args:
        file_path (Path): Path to the audio file.

    Returns:
        int: Number of detected frame errors.
    """
    try:
        error_result = ffmpeg.input(str(file_path)) \
            .output("null", f="null") \
            .global_args("-hide_banner", "-loglevel", "error") \
            .run(capture_stderr=True)

        return len(error_result[1].decode("utf-8").splitlines())

    except Exception as e:
        logging.debug(f"Warning: Could not check frame errors for {file_path}: {e}")
        return -1  # Indicate error state

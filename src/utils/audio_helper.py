import ffmpeg
import logging
import re
import traceback
from pathlib import Path


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
        logging.debug(f"FFmpeg Output (Silence Detection): {output==None}")

        # Extract silence periods using regex
        silence_matches = re.findall(r"silence_start:\s*([\d\.]+)", output)
        return [float(match) for match in silence_matches]

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.debug(f"Warning: Could not analyze silence for {file_path} at {tb.filename}:{tb.lineno}: {e}")

    return []


def extract_metadata(file_path):
    """
    Extracts audio metadata including duration, sample rate, bit rate, channels, and tags.

    Args:
        file_path (Path): Path to the audio file.

    Returns:
        dict: Contains duration (float), sample_rate (int), bit_rate (int), channels (int), and tags (dict).
    """
    results = {
        "duration": None,
        "sample_rate": None,
        "bit_rate": None,
        "channels": None,
        "tags": {}
    }

    try:
        probe = ffmpeg.probe(str(file_path))

        # Extract general file-level metadata
        format_data = probe.get("format", {})
        if "duration" in format_data:
            try:
                results["duration"] = float(format_data["duration"])
            except (ValueError, TypeError):
                logging.warning(f"Warning: Could not parse duration for {file_path}")

        # Extract first available audio stream
        audio_stream = next((s for s in probe["streams"] if s.get("codec_type") == "audio"), None)
        if audio_stream:
            try:
                results["sample_rate"] = int(audio_stream.get("sample_rate", 0)) or None
                results["bit_rate"] = int(audio_stream.get("bit_rate", 0)) if audio_stream.get("bit_rate") else None
                results["channels"] = int(audio_stream.get("channels", 0)) or None
            except (ValueError, TypeError):
                logging.warning(f"Warning: Issue parsing stream properties for {file_path}")

        # Extract tags from format-level metadata
        results["tags"] = format_data.get("tags", {}).copy()

        # Merge additional tags from all streams
        for stream in probe.get("streams", []):
            if "tags" in stream:
                print (stream["tags"])
                results["tags"].update(stream["tags"])  # Merge tags from multiple streams

    except ffmpeg.Error as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.error(f"FFmpeg error for {file_path} at {tb.filename}:{tb.lineno}: {e.stderr.decode() if e.stderr else e}")
        raise ValueError
    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.debug(f"Error extracting metadata for {file_path} at {tb.filename}:{tb.lineno}: {e}")
        raise ValueError

    logging.info(f"Metadata for {file_path.parent.name}/{file_path.name}: {results} from {audio_stream}.")
    return results



def check_frame_errors(file_path):
    """
    Checks for frame errors in an audio file using FFmpeg.

    Args:
        file_path (Path): Path to the audio file.

    Returns:
        int: Number of detected frame errors.
    """
    logging.debug(f"Checking frame errors for {file_path.parent.name}/{file_path.name}")
    try:
        error_result = ffmpeg.input(str(file_path)) \
            .output("null", f="null") \
            .global_args("-hide_banner", "-loglevel", "error") \
            .run(capture_stderr=True)

        frame_err_count = len(error_result[1].decode("utf-8").splitlines())
        logging.info(f"Frame errors for {file_path.parent.name}/{file_path.name} : {frame_err_count}.")
        return frame_err_count

    except Exception as e:
        logging.debug(f"Warning: Could not check frame errors for {file_path}: {e}")
        return -1  # Indicate error state

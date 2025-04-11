import ffmpeg
import logging
import re
import traceback
from pathlib import Path

def analyze_track(file_path, params, tests):
    """
    Performs a single-pass analysis on an audio file:
    - Extracts metadata
    - Analyzes loudness
    - Detects silence
    - Checks for frame errors

    Returns:
        dict with keys:
            - duration
            - sample_rate
            - bit_rate
            - channels
            - tags
            - loudness
            - silences
            - frame_errors
    """
    test_list = tests.split(",") if isinstance(tests, str) else []
    tests = [t.lower().strip() for t in test_list]  # Convert to a list for reusability

    results = {}
    results["metadata"] = extract_metadata(file_path)  # FFmpeg probe
    results["loudness"] = {}
    results["silences"] = {}
    results["frame_errors"] = 0

    logging.info(f"Performing audio tests {tests}.")

    if "loudness" in tests:
        results["loudness"] = analyze_loudness(file_path, params)

    if "silence" in tests:
        results["silences"] = detect_silence(file_path, params)

    if "frame_errors" in tests:
        results["frame_errors"] = check_frame_errors(file_path)
    
    return results


def analyze_loudness(file_path, params):
    """
    Analyzes loudness levels using FFmpeg's loudnorm filter.

    Returns:
        dict: {
            input_i: float,
            input_tp: float,
            input_lra: float,
            input_thresh: float,
            target_offset: float
        }
    """
    target_lufs = params.get("target_lufs", -19)

    try:
        result = ffmpeg.input(str(file_path)) \
            .filter("loudnorm", I=str(target_lufs), TP="-1.5", LRA="11", print_format="summary") \
            .output("null", f="null") \
            .global_args("-hide_banner") \
            .run(capture_stderr=True)

        output = result[1].decode("utf-8")
        # logging.debug(f"FFmpeg Output (Loudness): {output}")

        # Parse the new-style loudnorm summary
        metrics = {}

        patterns = {
            "input_i": r"Input Integrated:\s*(-?\d+\.?\d*)",
            "input_tp": r"Input True Peak:\s*([+-]?\d+\.?\d*)",
            "input_lra": r"Input LRA:\s*(\d+\.?\d*)",
            "input_thresh": r"Input Threshold:\s*(-?\d+\.?\d*)",
            "target_offset": r"Target Offset:\s*([+-]?\d+\.?\d*)"
        }

        for key, pattern in patterns.items():
            match = re.search(pattern, output)
            metrics[key] = float(match.group(1)) if match else None

        logging.debug(f"Loudness analysis for {file_path}:{metrics}")
        return metrics

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.debug(f"Warning: Could not analyze loudness for {file_path} at {tb.filename}:{tb.lineno}: {e}")

    return {
        "input_i": None,
        "input_tp": None,
        "input_lra": None,
        "input_thresh": None,
        "target_offset": None
    }

def detect_silence(file_path, params):
    """
    Detects silence in an audio file using FFmpeg.

    Args:
        file_path (Path): Path to the audio file.
        params (dict): Dictionary containing processing parameters.

    Returns:
        list: List of silence start times (float), or an empty list if no silence detected.
    """
    silence_threshold = params.get('silence_threshold', 90)
    min_silence_duration = params.get("min_silence_duration", 0.2)

    try:
        logging.debug(f"Checking {file_path} for silence")
        result = ffmpeg.input(str(file_path)) \
            .filter("silencedetect", noise=f"-{silence_threshold}dB", d=min_silence_duration) \
            .output("null", f="null") \
            .global_args("-hide_banner") \
            .run(capture_stderr=False)

        output = result[1].decode("utf-8")
        logging.debug(f"FFmpeg Output (Silence Detection {silence_threshold}||{min_silence_duration}): {output}")

        # Extract silence periods using regex
        silence_matches = re.findall(r"silence_start:\s*([\d\.]+)", output)
        silences = [float(match) for match in silence_matches]
        logging.debug(f"Checking {file_path} for silence: {silences}")
        return silences

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.warning(f"Warning: Could not analyze silence for {file_path} at {tb.filename}:{tb.lineno}: {e}")

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

    logging.debug(f"Metadata for {file_path.parent.name}/{file_path.name}: {results}")
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

        frame_err_count = len(error_result[1].decode("utf-8").splitlines())
        logging.debug(f"Checking {file_path} for frame errors: {frame_err_count}")
        return frame_err_count

    except Exception as e:
        logging.warning(f"Warning: Could not check frame errors for {file_path}: {e}")
        return -1  # Indicate error state

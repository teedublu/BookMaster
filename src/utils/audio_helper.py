import ffmpeg
import logging
import re
import traceback
from pathlib import Path

def analyze_track(file_path, params, tests):
    """
    Analyzes an audio file conditionally based on format/codec.
    Returns partial results even if some steps fail.
    """
    
    results = {
        "metadata": {},
        "loudness": {},
        "silences": [],
        "frame_errors": None,
        "errors": []
    }

    try:
        metadata = extract_metadata(file_path)
        results["metadata"] = metadata
    except Exception as e:
        logging.error(f"Failed metadata extraction: {file_path}: {e}")
        results["errors"].append(f"Metadata error: {e}")
        return results  # Metadata is fundamental; bail early.

    # Identify format and codec
    format_name = metadata.get("format_name", "").lower()
    codec_name = metadata.get("codec_name", "").lower()

    logging.info(f"Analyzing {file_path}: format={format_name}, codec={codec_name}, tests={tests}")

    if tests:
        test_list = tests.split(",") if isinstance(tests, str) else list(tests)
        test_list = [t.lower().strip() for t in test_list]

        # Selective test execution
        if "loudness" in test_list:
            if format_name in ["mp3", "aac", "ogg"] or codec_name.startswith("mp3"):
                results["loudness"] = analyze_loudness(file_path, params)
            else:
                logging.info(f"Skipping loudness: unsupported format {format_name}")
                results["errors"].append("Skipped loudness")

        if "silence" in test_list:
            if format_name in ["mp3", "aac", "ogg", "wav", "flac"]:
                results["silences"] = detect_silence(file_path, params)
            else:
                logging.info(f"Skipping silence detection: unsupported format {format_name}")
                results["errors"].append("Skipped silence detection")

        if "frame_errors" in test_list:
            if codec_name.startswith("mp3"):
                results["frame_errors"] = check_frame_errors(file_path)
            else:
                logging.info(f"Skipping frame error check: codec={codec_name} not frame-based")
                results["errors"].append("Skipped frame error check")

    return results


def extract_metadata(file_path):
    results = {
        "duration": None,
        "sample_rate": None,
        "bit_rate": None,
        "channels": None,
        "tags": {},
        "format_name": None,
        "codec_name": None
    }

    probe = ffmpeg.probe(str(file_path))

    format_data = probe.get("format", {})
    streams = probe.get("streams", [])

    if not isinstance(streams, list):
        raise ValueError(f"Invalid streams format in FFmpeg probe for {file_path}")

    audio_stream = next((s for s in streams if s.get("codec_type") == "audio"), None)

    if not audio_stream:
        raise ValueError(f"No valid audio stream found in {file_path}")

    results["format_name"] = format_data.get("format_name")
    results["tags"] = format_data.get("tags", {})
    results["sample_rate"] = try_parse_int(audio_stream.get("sample_rate"))
    results["bit_rate"] = try_parse_int(audio_stream.get("bit_rate"))
    results["channels"] = try_parse_int(audio_stream.get("channels"))
    results["codec_name"] = audio_stream.get("codec_name")
    results["duration"] = try_parse_float(format_data.get("duration"))

    if results["duration"] is None:
        # Try estimating
        frames = try_parse_int(audio_stream.get("nb_frames"))
        rate = try_parse_int(audio_stream.get("sample_rate"))
        if frames and rate:
            results["duration"] = frames / rate
            logging.info(f"Estimated duration from frames for {file_path}")
        else:
            logging.warning(f"Unable to determine duration for {file_path}")


    return results


def try_parse_float(value):
    try:
        return float(value) if value is not None else None
    except (ValueError, TypeError):
        return None

def try_parse_int(value):
    try:
        return int(value) if value is not None else None
    except (ValueError, TypeError):
        return None

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

    Args:detect_silence
        file_path (Path): Path to the audio file.
        params (dict): Dictionary containing processing parameters.

    Returns:
        list: List of silence start times (float), or an empty list if no silence detected.
    """
    silence_threshold = params.get('silence_threshold', 90)
    min_silence_duration = params.get("min_silence_duration", 0.2)

    try:
        logging.debug(f"Checking {file_path} for silence silence_threshold={silence_threshold}db min_silence_duration={min_silence_duration}s")
        result = ffmpeg.input(str(file_path)) \
            .filter("silencedetect", noise=f"-{silence_threshold}dB", d=min_silence_duration) \
            .output("null", f="null") \
            .global_args("-hide_banner") \
            .run(capture_stderr=False)

        if result[1]:
            output = result[1].decode("utf-8")
            logging.debug(f"FFmpeg Output (Silence Detection {silence_threshold}||{min_silence_duration}): {output}")

            # Extract silence periods using regex
            silence_matches = re.findall(r"silence_start:\s*([\d\.]+)", output)
            silences = [float(match) for match in silence_matches]
            logging.debug(f"Checking {file_path} for silence: {silences}")
            return silences
        else:
            return None

    except Exception as e:
        tb = traceback.extract_tb(e.__traceback__)[-1]
        logging.warning(f"Warning: Could not analyze silence for {file_path} at {tb.filename}:{tb.lineno}: {e}")

    return []

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

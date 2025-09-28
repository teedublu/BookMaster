import os
import logging
import fnmatch
from pathlib import Path
from typing import Literal
# from utils.audio_analysis import analyze_loudness, detect_silence
# from utils.file_utils import has_hidden_files, read_count_file, check_id3_tags, add_id3_tags, compute_checksum_file

class MasterValidator:
    def __init__(self, master, config=None):
        self.master = master
        self.config = config or {}

        self.failures = []
        self.improvements = []
        self.fix_log = []

    def validate(self) -> Literal["valid", "valid_but_improvable", "invalid"]:
        self._check_structure()
        self._check_required_files()
        self._check_audio_integrity()
        self._check_for_improvements()

        if self.failures:
            return "invalid"
        elif self.improvements:
            return "valid_but_improvable"
        return "valid"

    def _check_structure(self):
        required_files = ["bookInfo/id.txt", "bookInfo/count.txt"]
        for file in required_files:
            path = Path(self.master.input_folder) / file
            if not path.exists():
                self.failures.append(f"Missing required file: {file}")

    def _check_required_files(self):
        expected_count = read_count_file(Path(self.master.input_folder) / "bookInfo/count.txt")
        actual_files = [f for f in self.master.files if f.suffix == ".mp3"]
        if len(actual_files) != expected_count:
            self.failures.append(f"File count mismatch: expected {expected_count}, found {len(actual_files)}")

    def _check_audio_integrity(self):
        lufs_threshold = self.config.get("min_loudness_lufs", -18)
        for file in self.master.files:
            try:
                lufs = analyze_loudness(file)
                if lufs < lufs_threshold:
                    self.improvements.append(f"Loudness of {file.name} is {lufs:.2f} LUFS, below {lufs_threshold}")
                silence_warnings = detect_silence(file)
                self.improvements.extend([f"Silence in {file.name}: {w}" for w in silence_warnings])
            except Exception as e:
                self.failures.append(f"Audio integrity check failed for {file.name}: {e}")

    def _check_for_improvements(self):
        if has_hidden_files(self.master.input_folder):
            self.improvements.append("Folder contains hidden/system files")

        for file in self.master.files:
            if not check_id3_tags(file):
                self.improvements.append(f"Missing or incomplete ID3 tags in {file.name}")

        metadata_file = Path(self.master.input_folder) / ".metadata_never_index"
        if not metadata_file.exists():
            self.improvements.append("Missing .metadata_never_index file")

        checksum_file = Path(self.master.input_folder) / "bookInfo/checksum.txt"
        if not checksum_file.exists():
            self.improvements.append("Missing checksum file")

    def fix(self):
        """Attempts to auto-fix improvable issues."""
        patterns_to_remove = self.config.get("patterns_to_remove", [
            '._*'
        ])

        for root, dirs, files in os.walk(self.master.input_folder):
            for f in files:
                for pattern in patterns_to_remove:
                    if fnmatch.fnmatch(f, pattern):
                        try:
                            os.remove(Path(root) / f)
                            self.fix_log.append(f"Removed file matching pattern '{pattern}': {f}")
                        except Exception as e:
                            logging.warning(f"Failed to remove {f}: {e}")

        for file in self.master.files:
            if not check_id3_tags(file):
                try:
                    add_id3_tags(file, self.master)
                    self.fix_log.append(f"Added ID3 tags to {file.name}")
                except Exception as e:
                    logging.warning(f"Failed to add ID3 tags to {file.name}: {e}")

        metadata_file = Path(self.master.input_folder) / ".metadata_never_index"
        if not metadata_file.exists():
            try:
                metadata_file.touch()
                self.fix_log.append("Created .metadata_never_index file")
            except Exception as e:
                logging.warning(f"Failed to create .metadata_never_index: {e}")

        checksum_file = Path(self.master.input_folder) / "bookInfo/checksum.txt"
        if not checksum_file.exists():
            try:
                compute_checksum_file(self.master.files, checksum_file)
                self.fix_log.append("Created checksum file")
            except Exception as e:
                logging.warning(f"Failed to create checksum file: {e}")

        return self.fix_log

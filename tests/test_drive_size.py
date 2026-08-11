import sys
import unittest
import importlib.util
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

MODULE_PATH = Path(__file__).resolve().parents[1] / "src" / "models" / "drive_size.py"
spec = importlib.util.spec_from_file_location("drive_size", MODULE_PATH)
drive_size = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drive_size)

drive_size_bytes_to_mb = drive_size.drive_size_bytes_to_mb
drive_size_mb_to_bytes = drive_size.drive_size_mb_to_bytes
resolve_max_drive_size = drive_size.resolve_max_drive_size


class DummyConfig:
    params = {"max_drive_size": 980_000_000}


class DriveSizeTests(unittest.TestCase):
    def test_drive_size_mb_to_bytes_uses_decimal_mb(self):
        self.assertEqual(drive_size_mb_to_bytes("480"), 480_000_000)
        self.assertEqual(drive_size_mb_to_bytes("480 MB"), 480_000_000)

    def test_drive_size_bytes_to_mb_for_display(self):
        self.assertEqual(drive_size_bytes_to_mb(980_000_000), 980)

    def test_resolve_max_drive_size_prefers_per_run_mb_override(self):
        self.assertEqual(
            resolve_max_drive_size(DummyConfig(), {"max_drive_size_mb": "480"}),
            480_000_000,
        )

    def test_resolve_max_drive_size_keeps_raw_byte_override(self):
        self.assertEqual(
            resolve_max_drive_size(DummyConfig(), {"max_drive_size": 480_000_000}),
            480_000_000,
        )

    def test_resolve_max_drive_size_falls_back_to_config(self):
        self.assertEqual(resolve_max_drive_size(DummyConfig(), {}), 980_000_000)

    def test_drive_size_mb_to_bytes_rejects_invalid_values(self):
        for value in ["", "nope", "0", "-1"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    drive_size_mb_to_bytes(value)


if __name__ == "__main__":
    unittest.main()

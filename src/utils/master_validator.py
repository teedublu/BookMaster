from __future__ import annotations
from pathlib import Path
import logging, hashlib, os, re
from typing import Optional, Iterable
from dataclasses import dataclass
import shutil

# macOS / cross-OS “system clutter” you don’t want on a Voxblock drive

try:
    # Use existing impl if available (preferred for consistency)
    from utils import compute_sha256 as _compute_dir_sha256
except Exception:
    _compute_dir_sha256 = None  # fallback below

EXCLUDED_FILES = {"checksum.txt", ".DS_Store", "Thumbs.db", "version.txt"}
EXCLUDED_DIRS  = {".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"}
# Files that are OK to keep even if “hidden”
SYSTEM_EXEMPT = {".metadata_never_index"}  # keep this; helps avoid indexing




@dataclass(frozen=True)
class ValidationResult:
    ok: bool
    errors: tuple[str, ...] = ()
    warnings: tuple[str, ...] = ()
    def __bool__(self) -> bool:  # lets you do: if result:
        return self.ok
    def __str__(self) -> str:
        if self.ok and not self.warnings:
            return "OK"

        lines = []
        if not self.ok:
            lines.append("Errors:")
            lines += [f"- {e}" for e in self.errors]
        if self.warnings:
            lines.append("Warnings:")
            lines += [f"- {w}" for w in self.warnings]
        return "\n".join(lines)

class MasterValidator:
    """
    Validate a Voxblock 'master' layout located at a filesystem root.

    Now accepts either:
      - USBDrive (expects .mountpoint)
      - Master    (expects .master_path)
    Optionally pass expected_isbn to enforce id.txt.
    """

    def __init__(self, target, *, expected_isbn: Optional[str] = None):
        self.errors: list[str] = []
        self.warnings: list[str] = []

        # Back-compat: allow either Master or USBDrive
        if hasattr(target, "mountpoint"):              # USBDrive
            self.usb = target
            self.master = None
            self.root = Path(target.mountpoint).resolve()
        elif hasattr(target, "master_path"):           # Master
            self.master = target
            self.usb = None
            self.root = Path(target.master_path).resolve()
        else:
            raise TypeError("MasterValidator target must be a USBDrive (mountpoint) or Master (master_path)")

        self.expected_isbn = expected_isbn
        # Common, config-derived structure
        self.tracks_dir   = self.root / "tracks"
        self.bookinfo_dir = self.root / "bookInfo"
        self.id_txt       = self.bookinfo_dir / "id.txt"
        self.checksum_txt = self.bookinfo_dir / "checksum.txt"
        self.count_txt = self.bookinfo_dir / "count.txt"
        self.metadata_ni  = self.root / ".metadata_never_index"

        m = re.search(r"^/Volumes/(BK\d{5}[A-Z]{4})(?:/|$)", str(self.root))
        self.sku = m.group(1) if m else None

    # ----------------- public API -----------------

    def validate(self, *, fix_system_files: bool = False, **kwargs) -> ValidationResult:


        """Run all checks; returns True if OK. Errors collected in self.errors."""
        self.errors.clear()
        self.warnings.clear()

        self._system_files(fix_system_files)
        self._check_root_exists()
        self._ensure_metadata_never_index()
        self._check_tracks_folder()
        self._check_bookinfo_id()
        # self._check_checksum()

        return ValidationResult(ok=not self.errors,
                            errors=tuple(self.errors),
                            warnings=tuple(self.warnings))

    # ----------------- checks -----------------

    def _system_files(self, fix_system_files):
        # --- NEW: system files check / optional fix ---
        system_paths = self._scan_system_artifacts()
        if system_paths:
            # show short, readable relative list
            rels = [p.relative_to(self.root).as_posix() for p in system_paths]
            if fix_system_files:
                removed, fails = self._delete_paths(system_paths)
                if removed:
                    # warn that we changed the filesystem
                    preview = ", ".join(rels[:10]) + (" …" if len(rels) > 10 else "")
                    self.warnings.append(f"Removed {removed} system files/dirs: {preview}")
                if fails:
                    self.errors.append("Failed to remove some system files:\n- " + "\n- ".join(fails))
            else:
                preview = ", ".join(rels[:10]) + (" …" if len(rels) > 10 else "")
                self.errors.append(
                    "System files present on drive (use fix_system_files=True to remove): "
                    + preview
                )
        else:
            self.warnings.append(f"No system paths specified")


    def _check_root_exists(self):
        if not self.root.exists():
            self.errors.append(f"Root path does not exist: {self.root}")

    def _ensure_metadata_never_index(self):
        # Only warn if missing (you previously preferred not to auto-create)
        if not self.metadata_ni.exists():
            self.warnings.append(f"Missing {self.metadata_ni.name} at root.")
        elif not self.metadata_ni.is_file():
            self.errors.append(f"{self.metadata_ni} exists but is not a file.")

    def _check_tracks_folder(self):
        if not self.tracks_dir.exists():
            self.errors.append(f"Missing tracks folder: {self.tracks_dir}")
            return
        if not self.tracks_dir.is_dir():
            self.errors.append(f"'tracks' exists but is not a directory: {self.tracks_dir}")
            return

        # must contain at least one audio-like file
        exts = {".mp3", ".wav", ".wv", ".m4a", ".flac", ".aac"}
        audio = [
            p for p in self.tracks_dir.iterdir()
            if p.is_file()
            and p.suffix.lower() in exts
            and not p.name.startswith("._")     # ignore AppleDouble files
            and not p.name.startswith(".")      # ignore hidden dotfiles
        ]

        if not audio:
            self.errors.append(f"No audio files found in {self.tracks_dir}")
            # still continue to report count.txt issues if present
        actual_count = len(audio)

        # compare with /bookInfo/count.txt
        try:
            expected_str = self.count_txt.read_text(encoding="utf-8", errors="ignore").strip()
        except FileNotFoundError:
            self.errors.append(f"Missing count.txt: {self.count_txt}")
            return
        except Exception as e:
            self.errors.append(f"Unable to read count.txt: {e}")
            return

        try:
            expected_count = int(expected_str)
        except ValueError:
            self.errors.append(f"Invalid integer in count.txt ({self.count_txt}): {expected_str!r}")
            return

        if expected_count != actual_count:
            self.errors.append(
                f"Track count mismatch ({expected_count}v{actual_count})"
            )

        logging.debug(f"Found {expected_count} files and expecting {actual_count}")


    def _check_bookinfo_id(self):
        # bookInfo/ directory required
        if not self.bookinfo_dir.exists() or not self.bookinfo_dir.is_dir():
            self.errors.append(f"Missing bookInfo directory: {self.bookinfo_dir}")
            return

        # id.txt required
        if not self.id_txt.exists():
            self.errors.append(f"Missing id.txt: {self.id_txt}")
            return

        try:
            file_isbn = self.id_txt.read_text(encoding="utf-8", errors="ignore").strip()
            self.id = file_isbn
        except Exception as e:
            self.errors.append(f"Unable to read id.txt: {e}")
            return

        # If caller passed expected_isbn, enforce it
        if self.expected_isbn and file_isbn != self.expected_isbn:
            self.errors.append(f"ISBN mismatch: expected {self.expected_isbn}, found {file_isbn} in id.txt")

        # Back-compat: if a Master object was passed and it has .isbn, enforce equality
        if self.master and getattr(self.master, "isbn", None) and file_isbn != self.master.isbn:
            self.errors.append(f"ISBN mismatch: expected {self.master.isbn}, found {file_isbn} in id.txt")

    def _check_checksum(self):
        if not self.checksum_txt.exists():
            self.warnings.append(f"Missing checksum file: {self.checksum_txt}")
            return

        try:
            stored = self._read_checksum_file(self.checksum_txt)
        except Exception as e:
            self.errors.append(f"Unable to read checksum file {self.checksum_txt}: {e}")
            return

        try:
            actual = self._compute_dir_hash(self.root)
        except Exception as e:
            self.errors.append(f"Failed to compute checksum under {self.root}: {e}")
            return

        if stored != actual:
            self.errors.append(f"Checksums mismatch: stored={stored} actual={actual}")

    # ----------------- helpers -----------------

    @staticmethod
    def _read_checksum_file(path: Path) -> str:
        """
        Accept common formats, e.g.:
            <hex>
            <hex>  ./tracks/001.mp3
        Returns the first hex token on the first non-empty line.
        """
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            token = line.split()[0]
            return token.lower()
        raise ValueError("checksum.txt is empty")

    def _compute_dir_hash(self, root: Path) -> str:
        """
        Deterministic directory SHA-256 over all files except excluded ones.
        Uses project-provided utils.compute_sha256 if available; otherwise computes here.
        """
        if _compute_dir_sha256:
            # assume project version matches expected behavior
            return _compute_dir_sha256(root)

        sha = hashlib.sha256()
        for p in self._iter_files_for_hash(root):
            rel = p.relative_to(root).as_posix()
            sha.update(rel.encode("utf-8"))
            with p.open("rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    sha.update(chunk)
        return sha.hexdigest().lower()

    def _iter_files_for_hash(self, root: Path):
        for dirpath, dirnames, filenames in os.walk(root):
            # prune excluded dirs
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
            for name in filenames:
                if name in EXCLUDED_FILES:
                    continue
                p = Path(dirpath) / name
                # Always exclude the checksum file itself
                try:
                    if p.resolve() == self.checksum_txt.resolve():
                        continue
                except Exception:
                    pass
                yield p

    def _scan_system_artifacts(self) -> list[Path]:
        """Return dot-prefixed files/dirs under root (excluding explicit exemptions)."""
        artifacts: list[Path] = []
        root = self.root

        for dirpath, dirnames, filenames in os.walk(root):
            # capture & prune dot-directories (except exemptions)
            for d in list(dirnames):
                if d.startswith(".") and d not in SYSTEM_EXEMPT:
                    artifacts.append(Path(dirpath) / d)
                    dirnames.remove(d)  # don't descend into it

            # capture dot-files (including AppleDouble '._*'), except exemptions
            for name in filenames:
                if name.startswith(".") and name not in SYSTEM_EXEMPT:
                    artifacts.append(Path(dirpath) / name)

        return artifacts

    def _delete_paths(self, paths: list[Path]) -> tuple[int, list[str]]:
        """Delete files/dirs under root. Returns (removed_count, failures[relpath])."""
        removed = 0
        failures: list[str] = []
        for p in paths:
            # safety: ensure inside root
            try:
                p.relative_to(self.root)
            except ValueError:
                failures.append(f"Unsafe path outside root: {p}")
                continue

            try:
                if p.is_dir():
                    shutil.rmtree(p, ignore_errors=False)
                else:
                    p.unlink()
                removed += 1
            except Exception as e:
                failures.append(f"{p.relative_to(self.root).as_posix()}: {e}")
        return removed, failures

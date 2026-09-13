#!/usr/bin/env python3
"""Regress archive path validation used by the Windows resource build."""
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from prepare_windows_resources import extract_verified_tar


def write_archive(path, name, data=b"verified resource", entry_type=None, linkname=""):
    with tarfile.open(path, "w:gz") as archive:
        entry = tarfile.TarInfo(name)
        if entry_type is not None:
            entry.type = entry_type
            entry.linkname = linkname
        else:
            entry.size = len(data)
        archive.addfile(entry, None if entry_type is not None else io.BytesIO(data))


class ArchivePathTests(unittest.TestCase):
    def test_normalizes_destination_before_comparing_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "path-alias").mkdir()
            destination = root / "path-alias" / ".." / "ice"
            destination.mkdir()
            source = root / "safe.tar.gz"
            write_archive(source, "rime-ice/data/file.txt")

            extracted = extract_verified_tar(source, destination)

            self.assertEqual(extracted, destination.resolve())
            self.assertEqual((extracted / "rime-ice/data/file.txt").read_bytes(), b"verified resource")

    def test_rejects_parent_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "ice"
            destination.mkdir()
            source = root / "traversal.tar.gz"
            write_archive(source, "../outside.txt")

            with self.assertRaisesRegex(ValueError, "Unsafe upstream archive entry"):
                extract_verified_tar(source, destination)
            self.assertFalse((root / "outside.txt").exists())

    def test_rejects_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "ice"
            destination.mkdir()
            source = root / "link.tar.gz"
            write_archive(source, "rime-ice/link", entry_type=tarfile.SYMTYPE, linkname="../outside")

            with self.assertRaisesRegex(ValueError, "Unsafe upstream archive entry"):
                extract_verified_tar(source, destination)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Check that a mirror never weakens pinned dependency verification."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import prepare_resources as resources


class FetchTests(unittest.TestCase):
    def test_verified_cache_and_mirrors(self):
        trusted = b"the pinned model"
        metadata = {"url": "https://primary.invalid/model", "mirrors": ["https://mirror.invalid/model"],
                    "sha256": hashlib.sha256(trusted).hexdigest(), "bytes": len(trusted)}
        with tempfile.TemporaryDirectory() as temporary, patch.object(resources, "CACHE", Path(temporary)):
            path = Path(temporary) / "model.gram"
            def download(args, **kwargs):
                Path(args[args.index("--output") + 1]).write_bytes(b"replaced upstream asset" if args[-1] == metadata["url"] else trusted)
            with patch.object(subprocess, "run", side_effect=download) as run:
                self.assertEqual(resources.fetch(path.name, metadata).read_bytes(), trusted)
                self.assertEqual(run.call_count, 2)
                self.assertEqual(resources.fetch(path.name, metadata), path)
                self.assertEqual(run.call_count, 2)
            self.assertFalse(path.with_suffix(".gram.download").exists())

    def test_failed_sources_keep_cache_and_remove_partial_download(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(resources, "CACHE", Path(temporary)):
            path = Path(temporary) / "model.gram"
            path.write_bytes(b"previous cached version")
            def unavailable(args, **kwargs):
                Path(args[args.index("--output") + 1]).write_bytes(b"partial")
                raise subprocess.CalledProcessError(22, args)
            metadata = {"url": "https://primary.invalid/model", "mirrors": ["https://mirror.invalid/model"],
                        "sha256": hashlib.sha256(b"expected").hexdigest()}
            with patch.object(subprocess, "run", side_effect=unavailable), self.assertRaises(RuntimeError):
                resources.fetch(path.name, metadata)
            self.assertEqual(path.read_bytes(), b"previous cached version")
            self.assertFalse(path.with_suffix(".gram.download").exists())

    def test_matching_digest_does_not_bypass_size_check(self):
        data = b"model"
        metadata = {"url": "https://primary.invalid/model", "sha256": hashlib.sha256(data).hexdigest(), "bytes": 999}
        with tempfile.TemporaryDirectory() as temporary, patch.object(resources, "CACHE", Path(temporary)):
            path = Path(temporary) / "model.gram"
            path.write_bytes(data)
            def download(args, **kwargs):
                Path(args[args.index("--output") + 1]).write_bytes(data)
            with patch.object(subprocess, "run", side_effect=download), self.assertRaises(RuntimeError):
                resources.fetch(path.name, metadata)


if __name__ == "__main__":
    unittest.main()

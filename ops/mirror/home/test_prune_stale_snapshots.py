import os
from pathlib import Path
import tempfile
import unittest

import prune_stale_snapshots as prune


class SnapshotCleanupTests(unittest.TestCase):
    def make_tree(self, data):
        objects = data / "objects"
        objects.mkdir()
        public = data / "public/openwrt/releases/1/packages"
        public.parent.mkdir(parents=True)
        current = data / "snapshots/openwrt/feed/current"
        stale = data / "snapshots/openwrt/feed/stale"
        incomplete = data / "snapshots/openwrt/feed/incomplete"
        for path in (current, stale, incomplete):
            path.mkdir(parents=True)
        (current / ".complete").write_text("ok")
        (stale / ".complete").write_text("old")
        current_object = objects / ("a" * 64)
        stale_object = objects / ("b" * 64)
        incomplete_object = objects / ("c" * 64)
        for path, content in ((current_object, b"current"), (stale_object, b"stale"),
                              (incomplete_object, b"incomplete")):
            path.write_bytes(content)
        os.link(current_object, current / "current.apk")
        os.link(stale_object, stale / "stale.apk")
        os.link(incomplete_object, incomplete / "incomplete.apk")
        public.symlink_to(os.path.relpath(current, public.parent), target_is_directory=True)
        return current, stale, incomplete, current_object, stale_object, incomplete_object

    def test_dry_run_and_apply(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            current, stale, incomplete, current_object, stale_object, incomplete_object = self.make_tree(data)
            dry = prune.cleanup(data)
            self.assertEqual(dry["stale_completed"], 1)
            self.assertEqual(dry["published_preserved"], 1)
            self.assertEqual(dry["incomplete_preserved"], 1)
            self.assertTrue(stale.exists())
            applied = prune.cleanup(data, apply=True)
            self.assertEqual(applied["objects_removed"], 1)
            self.assertTrue(current.exists())
            self.assertTrue(incomplete.exists())
            self.assertFalse(stale.exists())
            self.assertTrue(current_object.exists())
            self.assertTrue(incomplete_object.exists())
            self.assertFalse(stale_object.exists())

    def test_missing_publication_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            stale = data / "snapshots/openwrt/feed/stale"
            stale.mkdir(parents=True)
            (stale / ".complete").write_text("old")
            (data / "public/openwrt/releases").mkdir(parents=True)
            with self.assertRaises(RuntimeError):
                prune.cleanup(data, apply=True)
            self.assertTrue(stale.exists())


if __name__ == "__main__":
    unittest.main()

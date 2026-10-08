import os
from pathlib import Path
import tempfile
import time
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
            self.assertEqual(dry["stale_incomplete"], 0)
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

    def test_old_incomplete_snapshot_is_removed_but_recent_one_is_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            current, _, recent, _, _, _ = self.make_tree(data)
            old = data / 'snapshots/openwrt/other/old-partial'
            old.mkdir(parents=True)
            obj = data / 'objects' / ('d' * 64)
            obj.write_bytes(b'old incomplete package')
            os.link(obj, old / 'old.ipk')
            eight_days_ago = time.time() - 8 * 24 * 60 * 60
            os.utime(old, (eight_days_ago, eight_days_ago))
            dry = prune.cleanup(data)
            self.assertEqual(dry['stale_incomplete'], 1)
            self.assertEqual(dry['incomplete_preserved'], 1)
            self.assertTrue(old.exists())
            applied = prune.cleanup(data, apply=True)
            self.assertEqual(applied['stale_incomplete'], 1)
            self.assertFalse(old.exists())
            self.assertFalse(obj.exists())
            self.assertTrue(recent.exists())
            self.assertTrue(current.exists())

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

    def test_only_unreferenced_list_snapshots_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            self.make_tree(data)
            lists = data / 'snapshots/lists'
            current = lists / '1791491106'
            old = lists / '1788881982'
            unknown = lists / 'keep-me'
            for path in (current, old, unknown):
                path.mkdir(parents=True)
                (path / 'rule.srs').write_bytes(b'list')
            public = data / 'public/forkop/lists'
            public.parent.mkdir(parents=True)
            public.symlink_to(os.path.relpath(current, public.parent), target_is_directory=True)
            dry = prune.cleanup(data)
            self.assertEqual(dry['stale_lists'], 1)
            prune.cleanup(data, apply=True)
            self.assertTrue(current.exists())
            self.assertTrue(unknown.exists())
            self.assertFalse(old.exists())
            self.assertEqual(public.resolve(), current)

    def test_broken_published_list_link_blocks_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            self.make_tree(data)
            lists = data / 'snapshots/lists'
            lists.mkdir(parents=True)
            (lists / '1788881982').mkdir()
            public = data / 'public/forkop/lists'
            public.parent.mkdir(parents=True)
            public.symlink_to(lists / 'missing', target_is_directory=True)
            with self.assertRaises(RuntimeError):
                prune.cleanup(data, apply=True)
            self.assertTrue((lists / '1788881982').exists())


if __name__ == "__main__":
    unittest.main()

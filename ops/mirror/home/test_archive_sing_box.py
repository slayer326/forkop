import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from archive_sing_box import collect, package_identity


class SingBoxArchiveTests(unittest.TestCase):
    def test_filename_identity(self):
        self.assertEqual(package_identity('sing-box_1.14.0-r1_aarch64_cortex-a53.ipk',
                                          'aarch64_cortex-a53')['version'], '1.14.0-r1')
        self.assertEqual(package_identity('sing-box-tiny-1.14.0-r1.apk',
                                          'aarch64_generic')['package'], 'sing-box-tiny')
        self.assertIsNone(package_identity('sing-box_1.14.0-r1_x86_64.ipk',
                                           'aarch64_cortex-a53'))
        self.assertIsNone(package_identity('../sing-box-1.apk', 'aarch64_generic'))

    def test_retains_published_package_after_feed_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            public = root / 'public'
            snapshots = root / 'snapshots' / 'openwrt'
            feed = snapshots / 'feed' / 'complete'
            feed.mkdir(parents=True)
            (feed / '.complete').write_text('done')
            name = 'sing-box_1.14.0-r1_aarch64_cortex-a53.ipk'
            content = b'verified package from complete feed'
            (feed / name).write_bytes(content)
            link = public / 'openwrt' / 'releases' / '24.10.5' / 'packages' / 'aarch64_cortex-a53' / 'packages'
            link.parent.mkdir(parents=True)
            link.symlink_to(feed, target_is_directory=True)
            archive = public / 'forkop' / 'sing-box-archive'
            self.assertEqual(collect(public, snapshots, archive), 1)
            digest = hashlib.sha256(content).hexdigest()
            catalog = json.loads((archive / 'packages.json').read_text())
            self.assertEqual(catalog['packages'][0]['sha256'], digest)
            blob = archive / 'blobs' / digest / name
            self.assertEqual(blob.read_bytes(), content)
            link.unlink()
            (feed / name).unlink()
            self.assertEqual(collect(public, snapshots, archive), 1)
            self.assertEqual(blob.read_bytes(), content)

    def test_rejects_corrupted_existing_blob_without_replacing_catalog(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            public = root / 'public'
            archive = public / 'forkop' / 'sing-box-archive'
            snapshots = root / 'snapshots' / 'openwrt'
            feed = snapshots / 'feed' / 'complete'
            feed.mkdir(parents=True)
            (feed / '.complete').write_text('done')
            name = 'sing-box-1.14.0-r1.apk'
            (feed / name).write_bytes(b'good')
            link = public / 'openwrt' / 'releases' / 'packages-25.12' / 'aarch64_generic' / 'packages'
            link.parent.mkdir(parents=True)
            link.symlink_to(feed, target_is_directory=True)
            self.assertEqual(collect(public, snapshots, archive), 1)
            catalog = (archive / 'packages.json').read_bytes()
            digest = hashlib.sha256(b'good').hexdigest()
            (archive / 'blobs' / digest / name).write_bytes(b'bad')
            with self.assertRaises(ValueError):
                collect(public, snapshots, archive)
            self.assertEqual((archive / 'packages.json').read_bytes(), catalog)


if __name__ == '__main__':
    unittest.main()

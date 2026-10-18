import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('package_dependencies', Path(__file__).with_name('package-dependencies.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / '.build/checkouts/example'
        self.checkout.mkdir(parents=True)
        self.binaries = self.root / 'bin'
        self.binaries.mkdir()
        self.resources = self.root / 'resources'
        self.resources.mkdir()
        self.pin = {'identity': 'example', 'location': 'https://example.invalid/example.git',
                    'state': {'version': '1.0.0', 'revision': 'a' * 40}}
        (self.root / 'Package.resolved').write_text(json.dumps({'pins': [self.pin]}))
        (self.checkout / 'LICENSE').write_text('Fixture license\n')
        bundle = self.binaries / 'SwiftProtobuf_SwiftProtobuf.bundle'
        bundle.mkdir()
        (bundle / 'PrivacyInfo.xcprivacy').write_text('fixture')

    def package(self):
        module.package_dependencies(self.root, self.binaries, self.resources)

    def test_copies_notices_nested_licenses_resources_and_manifest(self):
        nested = self.checkout / 'Sources/vendor'
        nested.mkdir(parents=True)
        (nested / 'LICENSE.txt').write_text('Nested license')
        self.package()
        notices = self.resources / 'ThirdPartyNotices'
        self.assertEqual((notices / 'example/LICENSE').read_text(), 'Fixture license\n')
        self.assertEqual((notices / 'example/Sources/vendor/LICENSE.txt').read_text(), 'Nested license')
        self.assertTrue((self.resources / 'SwiftProtobuf_SwiftProtobuf.bundle/PrivacyInfo.xcprivacy').is_file())
        manifest = json.loads((notices / 'manifest.json').read_text())
        self.assertEqual(manifest[0]['state'], self.pin['state'])
        self.assertEqual(len(manifest[0]['notices']), 2)
        self.assertTrue(all(len(item['sha256']) == 64 for item in manifest[0]['notices']))

    def test_missing_license_fails(self):
        (self.checkout / 'LICENSE').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing root license'):
            self.package()

    def test_missing_resource_bundle_fails(self):
        (self.binaries / 'SwiftProtobuf_SwiftProtobuf.bundle').rename(self.binaries / 'wrong-name')
        with self.assertRaisesRegex(ValueError, 'Missing SwiftProtobuf'):
            self.package()

    def test_empty_runtime_bundle_fails(self):
        (self.binaries / 'SwiftProtobuf_SwiftProtobuf.bundle/PrivacyInfo.xcprivacy').unlink()
        with self.assertRaisesRegex(ValueError, 'Empty resource bundle'):
            self.package()

    def test_nested_bundle_symlink_is_not_followed(self):
        outside = self.root / 'unrelated.txt'
        outside.write_text('Not a runtime resource')
        (self.binaries / 'SwiftProtobuf_SwiftProtobuf.bundle/linked.txt').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'Symlink in resource bundle'):
            self.package()
        self.assertFalse((self.resources / 'SwiftProtobuf_SwiftProtobuf.bundle').exists())

    def test_existing_notice_tree_is_not_overwritten(self):
        (self.resources / 'ThirdPartyNotices').mkdir()
        with self.assertRaises(FileExistsError):
            self.package()


if __name__ == '__main__':
    unittest.main()

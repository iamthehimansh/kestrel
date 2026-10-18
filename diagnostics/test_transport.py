import tempfile
import unittest
from pathlib import Path
from transport import TransportBoot, configured_transport, configured_refresh


class TransportTests(unittest.TestCase):
    def test_changes_only_transport(self):
        original = b'hw.cpu.ncore=2\nhw.gltransport=pipe\nhw.ramSize=3072\n'
        self.assertEqual(configured_transport(original, 'asg'),
                         b'hw.cpu.ncore=2\nhw.ramSize=3072\nhw.gltransport=asg\n')

    def test_replaces_duplicate_entries(self):
        result = configured_transport(b'hw.gltransport=pipe\nhw.gltransport=asg\n', 'pipe')
        self.assertEqual(result, b'hw.gltransport=pipe\n')

    def test_rejects_arbitrary_transport(self):
        with self.assertRaises(ValueError):
            configured_transport(b'', 'unsupported')

    def test_refresh_override_preserves_other_settings(self):
        original = b'hw.cpu.ncore=2\nhw.lcd.vsync=60\nhw.lcd.vsync=90\nhw.gltransport=pipe\n'
        self.assertEqual(configured_refresh(original, 120),
                         b'hw.cpu.ncore=2\nhw.gltransport=pipe\nhw.lcd.vsync=120\n')

    def test_refresh_rejects_invalid_values(self):
        for value in [0, -60, 75, 120.0, True, '120']:
            with self.assertRaises(ValueError):
                configured_refresh(b'', value)

    def test_cleanup_restores_exact_config_even_without_process(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'avd/kestrel-0.avd/config.ini'
            config.parent.mkdir(parents=True)
            original = b'# original\r\nhw.ramSize=3072\r\n'
            config.write_bytes(original)
            boot = TransportBoot(home, Path('/unused'), {}, 'asg', home, lambda _: None)
            config.write_bytes(configured_transport(original, 'asg'))
            boot.stop(lambda *args: self.fail('No process should be contacted'), {})
            self.assertEqual(config.read_bytes(), original)

    def test_snapshot_flag_requires_vulkan_and_boolean(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'avd/kestrel-0.avd/config.ini'
            config.parent.mkdir(parents=True)
            config.write_bytes(b'hw.ramSize=3072\n')
            for settings, enabled in [({'vulkan': False}, True), ({'vulkan': True}, 'on')]:
                with self.assertRaises(ValueError):
                    TransportBoot(home, Path('/unused'), settings, 'pipe', home, lambda _: None,
                                  vulkan_snapshots=enabled)
            boot = TransportBoot(home, Path('/unused'), {'vulkan': True}, 'pipe', home, lambda _: None)
            self.assertFalse(boot.vulkan_snapshots)
            self.assertEqual(config.read_bytes(), b'hw.ramSize=3072\n')

    def test_async_swap_override_is_explicit_boolean_and_default_off(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'avd/kestrel-0.avd/config.ini'
            config.parent.mkdir(parents=True)
            config.write_bytes(b'hw.ramSize=3072\n')
            boot = TransportBoot(home, Path('/unused'), {}, 'pipe', home, lambda _: None)
            self.assertFalse(boot.disable_async_swap)
            enabled = TransportBoot(home, Path('/unused'), {}, 'pipe', home, lambda _: None,
                                    disable_async_swap=True)
            self.assertTrue(enabled.disable_async_swap)
            for invalid in [1, 'true', None]:
                with self.assertRaises(ValueError):
                    TransportBoot(home, Path('/unused'), {}, 'pipe', home, lambda _: None,
                                  disable_async_swap=invalid)
            self.assertEqual(config.read_bytes(), b'hw.ramSize=3072\n')

    def test_grpc_requires_explicit_policy_and_valid_port(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'avd/kestrel-0.avd/config.ini'
            config.parent.mkdir(parents=True)
            config.write_bytes(b'hw.ramSize=3072\n')
            for port, policy in [(8556, None), (None, home/'access.json'), (80, home/'access.json'),
                                 (True, home/'access.json')]:
                with self.assertRaises(ValueError):
                    TransportBoot(home, Path('/unused'), {}, 'pipe', home, lambda _: None,
                                  grpc_port=port, grpc_allowlist=policy)
            boot = TransportBoot(home, Path('/unused'), {}, 'pipe', home, lambda _: None)
            self.assertIsNone(boot.grpc_port)

    def test_rejects_nonisolated_home_before_mutating(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / 'avd/kestrel-0.avd/config.ini'
            config.parent.mkdir(parents=True)
            config.write_bytes(b'hw.ramSize=3072\n')
            boot = TransportBoot(home, Path('/unused'), {}, 'asg', home, lambda _: None)
            with self.assertRaises(RuntimeError):
                boot.start(lambda *args: self.fail('No process should start'), {})
            self.assertEqual(config.read_bytes(), boot.original)


if __name__ == '__main__':
    unittest.main(verbosity=2)

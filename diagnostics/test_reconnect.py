import unittest
from reconnect import wait_for_adb


class ReconnectTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.calls = []

    def sleep(self, seconds):
        self.now += seconds

    def test_recovers_only_selected_serial(self):
        responses = iter([RuntimeError('device offline'), 'device\n', '0\n', 'device\n', '1\n'])
        def command(args, env, timeout):
            self.calls.append(args)
            value = next(responses)
            if isinstance(value, Exception):
                raise value
            return value
        wait_for_adb(command, 'adb', 'emulator-5580', {}, lambda _: None, timeout=5,
                     clock=lambda: self.now, sleep=self.sleep)
        self.assertEqual(self.now, 2)
        self.assertTrue(all(args[:3] == ['adb', '-s', 'emulator-5580'] for args in self.calls))
        self.assertFalse(any('kill-server' in args or 'disconnect' in args for args in self.calls))

    def test_offline_exits_at_deadline(self):
        def command(args, env, timeout):
            self.calls.append(args)
            raise RuntimeError('device offline')
        with self.assertRaisesRegex(RuntimeError, 'deadline exceeded'):
            wait_for_adb(command, 'adb', 'emulator-5580', {}, lambda _: None, timeout=3,
                         clock=lambda: self.now, sleep=self.sleep)
        self.assertEqual(self.now, 3)
        self.assertEqual(len(self.calls), 3)

    def test_online_without_android_ready_is_not_success(self):
        def command(args, env, timeout):
            return 'device' if args[-1] == 'get-state' else '0'
        with self.assertRaises(RuntimeError):
            wait_for_adb(command, 'adb', 'emulator-5580', {}, lambda _: None, timeout=2,
                         clock=lambda: self.now, sleep=self.sleep)
        self.assertEqual(self.now, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)

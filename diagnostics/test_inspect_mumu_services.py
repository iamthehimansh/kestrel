import unittest
from inspect_mumu_services import collect, diagnostic_serial


class MuMuServiceInspectionTests(unittest.TestCase):
    def setUp(self):
        self.identity = {'index': 1, 'name': 'Kestrel Diagnostic Baseline', 'bundle_path': '/fixture/diagnostic.gmad'}
        self.current = dict(self.identity, state='running', adb_port=16384)

    def test_accepts_exact_running_diagnostic(self):
        self.assertEqual(diagnostic_serial(self.identity, self.current), '127.0.0.1:16384')

    def test_rejects_original_instance_and_mismatched_identity(self):
        for index in [0, -1, True, '1', None]:
            with self.subTest(index=index), self.assertRaises(ValueError):
                diagnostic_serial(dict(self.identity, index=index), self.current)
        for changes in [{'name': 'My game'}, {'bundle_path': '/other.gmad'}, {'state': 'stopped'},
                        {'adb_port': 1}, {'adb_port': 65536}, {'adb_port': True}, {'adb_port': '16384'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                diagnostic_serial(self.identity, dict(self.current, **changes))
        with self.assertRaises(ValueError):
            diagnostic_serial(dict(self.identity, bundle_path=''), dict(self.current, bundle_path=''))

    def test_queries_are_read_only_and_unavailable_is_not_absent(self):
        calls = []
        def shell(args):
            calls.append(args)
            if args == ['cat', '/proc/sys/vm/pagecache_limit_policy']:
                raise RuntimeError('Permission denied')
            return 'fixture output\n'
        observed = collect(shell)
        self.assertEqual(len(calls), 14)
        for name, path in [('prefetch_system_metadata', '/system/etc/mumu-configs/prefetch.config'),
                           ('prefetch_override_metadata', '/data/system/etc/mumu-configs/prefetch.config')]:
            self.assertIn(['stat', '-c', '%s %Y', path], calls)
            self.assertEqual(observed[name]['status'], 'observed')
        self.assertIn(['getprop', 'sys.enable_screen'], calls)
        self.assertIn(['cat', '/proc/mounts'], calls)
        self.assertEqual(observed['screen_enabled']['status'], 'observed')
        self.assertEqual(observed['guest_mounts']['status'], 'observed')
        self.assertEqual({args[0] for args in calls}, {'getprop', 'cat', 'ps', 'stat'})
        self.assertTrue(all(not any(c in arg for c in [';', '|', '>', '\n']) for args in calls for arg in args))
        self.assertEqual(observed['pagecache_policy']['status'], 'unavailable')
        self.assertNotIn('output', observed['pagecache_policy'])
        self.assertEqual(observed['platform'], {'status': 'observed', 'output': 'fixture output\n'})
        self.assertEqual(observed['memory_info']['status'], 'observed')


if __name__ == '__main__':
    unittest.main()

import unittest
from unittest.mock import patch
from refresh import RefreshPreferences


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.values = {'peak_refresh_rate': '90.0', 'min_refresh_rate': 'null'}
        self.calls = []
        self.fail_write = None
        self.sync_count = 0
        sleeper_patch = patch('refresh.time.sleep')
        self.sleeper = sleeper_patch.start()
        self.addCleanup(sleeper_patch.stop)

    def shell(self, command, operation=None, namespace=None, key=None, *value):
        if command == 'sync':
            self.sync_count += 1
            self.sleeper.assert_called_once_with(5)
            return ''
        self.calls.append((operation, key, value))
        if operation == 'get':
            return self.values[key] + '\n'
        if operation == 'put':
            if key == self.fail_write:
                raise RuntimeError('simulated failure')
            self.values[key] = value[0]
        elif operation == 'delete':
            self.values[key] = 'null'
        return ''

    def test_restores_unset_and_existing_values(self):
        preferences = RefreshPreferences(self.shell)
        preferences.apply(120)
        self.assertEqual(self.values, {'peak_refresh_rate': '120', 'min_refresh_rate': '120'})
        preferences.restore()
        self.assertEqual(self.values, {'peak_refresh_rate': '90.0', 'min_refresh_rate': 'null'})
        self.assertEqual(preferences.changed, [])

    def test_peak_only_does_not_touch_minimum(self):
        preferences = RefreshPreferences(self.shell)
        preferences.apply(120, peak_only=True)
        self.assertEqual(self.values, {'peak_refresh_rate': '120', 'min_refresh_rate': 'null'})
        preferences.restore()
        self.assertEqual(self.values, {'peak_refresh_rate': '90.0', 'min_refresh_rate': 'null'})
        self.assertTrue(all(key == 'peak_refresh_rate' for _, key, _ in self.calls))

    def test_partial_failure_can_restore(self):
        preferences = RefreshPreferences(self.shell)
        self.fail_write = 'min_refresh_rate'
        with self.assertRaises(RuntimeError):
            preferences.apply(120)
        self.fail_write = None
        preferences.restore()
        self.assertEqual(self.values, {'peak_refresh_rate': '90.0', 'min_refresh_rate': 'null'})

    def test_restoration_attempts_both_after_failure(self):
        preferences = RefreshPreferences(self.shell)
        preferences.apply(120)
        preferences.original['min_refresh_rate'] = '60'
        self.fail_write = 'min_refresh_rate'
        with self.assertRaisesRegex(RuntimeError, 'restoration failed'):
            preferences.restore()
        self.assertEqual(self.values['peak_refresh_rate'], '90.0')

    def test_restoration_settles_then_syncs_before_clearing(self):
        preferences = RefreshPreferences(self.shell)
        preferences.apply(120)
        preferences.restore()
        self.sleeper.assert_called_once_with(5)
        self.assertEqual(self.sync_count, 1)
        self.assertEqual(preferences.changed, [])

    def test_sync_failure_retains_cleanup_state(self):
        preferences = RefreshPreferences(self.shell)
        preferences.apply(120)
        original_shell = preferences.shell
        def failing_sync(*args):
            if args == ('sync',):
                raise RuntimeError('sync failed')
            return original_shell(*args)
        preferences.shell = failing_sync
        with self.assertRaisesRegex(RuntimeError, 'sync failed'):
            preferences.restore()
        self.assertEqual(len(preferences.changed), 2)

    def test_no_changes_needs_no_settle(self):
        RefreshPreferences(self.shell).restore()
        self.sleeper.assert_not_called()
        self.assertEqual(self.sync_count, 0)

    def test_invalid_rate_does_not_touch_guest(self):
        for value in [0, 75, 120.0, True]:
            with self.assertRaises(ValueError):
                RefreshPreferences(self.shell).apply(value)
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)

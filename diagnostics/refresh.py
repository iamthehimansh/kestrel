"""Temporary Android user refresh preferences for an explicitly isolated test VM."""
import time


class RefreshPreferences:
    KEYS = ('peak_refresh_rate', 'min_refresh_rate')

    def __init__(self, shell):
        self.shell = shell
        self.original = {}
        self.changed = []

    def apply(self, hz, peak_only=False):
        if type(hz) is not int or hz not in (30, 60, 90, 120, 144, 165, 240):
            raise ValueError('Unsupported refresh rate')
        if self.changed:
            raise RuntimeError('Preferences already applied')
        # Capture affected values before mutation, preserving unset versus explicit values.
        # Peak-only experiments must never read or write the user's minimum preference.
        keys = ('peak_refresh_rate',) if peak_only else self.KEYS
        for key in keys:
            self.original[key] = self.shell('settings', 'get', 'system', key).strip()
        for key in keys:
            self.changed.append(key)
            self.shell('settings', 'put', 'system', key, str(hz))
            observed = self.shell('settings', 'get', 'system', key).strip()
            if float(observed) != hz:
                raise RuntimeError('Refresh preference did not persist: ' + key)

    def restore(self):
        errors = []
        for key in reversed(self.changed):
            try:
                value = self.original[key]
                operation = ('delete', 'system', key) if value == 'null' else ('put', 'system', key, value)
                self.shell('settings', *operation)
                if self.shell('settings', 'get', 'system', key).strip() != value:
                    raise RuntimeError('Restored value does not match')
            except Exception as error:
                errors.append(f'{key}: {error}')
        if errors:
            raise RuntimeError('Refresh restoration failed: ' + '; '.join(errors))
        if self.changed:
            # SettingsProvider queues disk writes; immediate readback only checks memory.
            # Cold-reboot audits remain necessary: this grace period is not an atomic flush.
            time.sleep(5)
            self.shell('sync')
            for key in self.changed:
                if self.shell('settings', 'get', 'system', key).strip() != self.original[key]:
                    raise RuntimeError('Refresh value changed during persistence wait: ' + key)
        self.changed.clear()

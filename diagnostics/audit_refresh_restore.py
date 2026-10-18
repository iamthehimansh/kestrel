#!/usr/bin/env python3
"""Cold-reboot audit of settings restoration on the known disposable refresh profile."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import time
from run import command, log, wait, ROOT
from transport import TransportBoot
from refresh import RefreshPreferences


def main():
    home = Path('/tmp/kestrel-perf-refresh-clean-11').resolve()
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / '.cocreate/research/refresh-restoration-audit-02')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk))
    settings = json.loads((home / 'instances/0/settings.json').read_text())
    assert settings['name'] == 'Fresh refresh probe', 'Unexpected profile'
    prior = json.loads((ROOT / '.cocreate/research/refresh120-peak-clean-04/summary.json').read_text())
    assert prior['original_refresh_preferences'] == {'peak_refresh_rate': 'null'}
    report = {'status': 'running', 'home': str(home), 'expected_peak_after_reboot': 'null'}
    boot = None

    def shell(*parts):
        return command([adb, '-s', 'emulator-5580', 'shell', *parts], env, 20)

    def values():
        return {k: shell('settings', 'get', 'system', k).strip() for k in RefreshPreferences.KEYS}

    try:
        log('[1/4] Check isolation and boot the known disposable refresh profile')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing ADB device'
        first = output / 'before'
        first.mkdir()
        boot = TransportBoot(home, sdk, settings, 'pipe', first, log, refresh_hz=120)
        boot.start(command, env)
        report['after_previous_shutdown'] = values()
        log('  Persisted values: ' + json.dumps(report['after_previous_shutdown']))
        assert report['after_previous_shutdown'] == {'peak_refresh_rate': 'null', 'min_refresh_rate': 'null'}, 'Expected clean audited profile'
        log('[2/4] Apply both preferences, then exercise the production diagnostic cleanup helper')
        preferences = RefreshPreferences(shell)
        try:
            preferences.apply(120)
            report['during_experiment'] = values()
            assert report['during_experiment'] == {'peak_refresh_rate': '120', 'min_refresh_rate': '120'}
            wait(5, 'allow experimental values to persist before testing restoration')
            shell('sync')
        finally:
            preferences.restore()
        report['before_shutdown'] = values()
        assert report['before_shutdown']['peak_refresh_rate'] == 'null'
        assert report['before_shutdown']['min_refresh_rate'] == report['after_previous_shutdown']['min_refresh_rate']
        boot.stop(command, env)
        boot = None
        wait(3, 'allow ADB transport teardown')
        log('[3/4] Cold boot again; verify restored preference persisted')
        second = output / 'after'
        second.mkdir()
        boot = TransportBoot(home, sdk, settings, 'pipe', second, log, refresh_hz=120)
        boot.start(command, env)
        report['after_cold_reboot'] = values()
        (output / 'display-after-reboot.txt').write_text(shell('dumpsys', 'display'))
        assert report['after_cold_reboot'] == report['before_shutdown'], 'Preferences did not persist across cold boot'
        report['status'] = 'completed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = str(exc)
        raise
    finally:
        log('[4/4] Stop only owned diagnostic VM and retain audit evidence')
        if boot is not None:
            try:
                boot.stop(command, env)
            except Exception as exc:
                report['status'] = 'failed'
                report['cleanup_error'] = str(exc)
        (output / 'report.json').write_text(json.dumps(report, indent=2))
        log('SUMMARY: ' + json.dumps(report))
    if report['status'] != 'completed':
        raise RuntimeError('Audit cleanup failed')


if __name__ == '__main__':
    main()

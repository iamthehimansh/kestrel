#!/usr/bin/env python3
"""Verify normal Kestrel CLI refresh plumbing without changing guest preferences."""
import fcntl
import json
import os
from pathlib import Path
import re
from run import command, log, ROOT


def main():
    home = Path('/tmp/kestrel-perf-refresh-clean-11').resolve()
    output = ROOT / '.cocreate/research/product-refresh-01'
    output.mkdir(parents=True, exist_ok=False)
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    settings_path = home / 'instances/0/settings.json'
    original = settings_path.read_bytes()
    settings = json.loads(original)
    assert settings['name'] == 'Fresh refresh probe', 'Not the disposable profile'
    cli = ROOT / '.build/debug/kestrel'
    adb = Path.home() / 'Library/Android/sdk/platform-tools/adb'
    env = dict(os.environ, KESTREL_HOME=str(home))
    report = {'status': 'running', 'home': str(home)}
    started = False
    changed = False
    try:
        log('[1/4] Check isolation and resource availability')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing device'
        (output / 'host-memory.txt').write_text(command(['vm_stat'], env))
        log('[2/4] Set virtual refresh through normal CLI and boot')
        changed = True
        command([cli, 'config', '0', '--set', '{"fpsLimit":120}'], env)
        config = (home / 'avd/kestrel-0.avd/config.ini').read_text()
        (output / 'config.ini').write_text(config)
        assert 'hw.lcd.vsync=120\n' in config, 'Product did not generate virtual refresh setting'
        started = True
        print(command([cli, 'start', '0', '--cold', '--wait'], env, 360), flush=True)
        log('[3/4] Verify guest display and untouched Android preferences')
        def shell(*parts):
            return command([adb, '-s', 'emulator-5580', 'shell', *parts], env, 30)
        assert shell('getprop', 'sys.boot_completed').strip() == '1'
        display = shell('dumpsys', 'display')
        (output / 'display.txt').write_text(display)
        preferences = {key: shell('settings', 'get', 'system', key).strip()
                       for key in ('peak_refresh_rate', 'min_refresh_rate')}
        report['preferences'] = preferences
        assert all(v == 'null' for v in preferences.values()), 'Product changed guest refresh preferences'
        assert re.search(r'peakRefreshRate[= ]+120(?:\.|\b)', display), 'No 120Hz virtual display mode'
        bootlog = (home / 'instances/0/emulator.log').read_text()
        (output / 'emulator.log').write_text(bootlog)
        assert 'androidboot.qemu.vsync=120' in bootlog, 'Host did not pass 120Hz boot setting'
        report['virtual_display_hz'] = 120
        report['status'] = 'completed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = str(exc)
        raise
    finally:
        log('[4/4] Stop owned VM and restore original test profile settings')
        try:
            if started:
                print(command([cli, 'stop', '0'], env, 45), flush=True)
            if changed:
                command([cli, 'config', '0', '--set', json.dumps({'fpsLimit': settings['fpsLimit']})], env)
                assert json.loads(settings_path.read_bytes()) == settings, 'Test settings not restored'
                report['settings_restored'] = True
        except Exception as exc:
            report['status'] = 'failed'
            report['cleanup_error'] = str(exc)
        (output / 'report.json').write_text(json.dumps(report, indent=2))
        log('SUMMARY: ' + json.dumps(report))
    if report['status'] != 'completed':
        raise RuntimeError('Cleanup failed')


if __name__ == '__main__':
    main()

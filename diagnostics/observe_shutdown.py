#!/usr/bin/env python3
"""Observe normal CLI stop against an owned emulator, including actual child exit status."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import time
from run import command, log, wait, ROOT
from reconnect import wait_for_adb


def main():
    home = Path('/tmp/kestrel-perf-capacity-fixed-10').resolve()
    out = ROOT / '.cocreate/research/shutdown-observation-01'
    out.mkdir(parents=True, exist_ok=False)
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    cli = ROOT / '.build/debug/kestrel'
    env = dict(os.environ, KESTREL_HOME=str(home), ANDROID_SDK_ROOT=str(sdk),
               ANDROID_AVD_HOME=str(home / 'avd'), ANDROID_EMU_VK_ICD='moltenvk')
    settings = json.loads((home / 'instances/0/settings.json').read_text())
    assert settings['name'] == 'Startup probe' and settings['memoryMB'] == 3072
    rows = []
    process = None
    stop = None
    report = {'status': 'running', 'samples': rows}
    try:
        log('[1/3] Check isolation and regenerate normal product configuration')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing ADB device'
        (out / 'memory.txt').write_text(command(['vm_stat'], env))
        command([cli, 'config', '0', '--set', '{}'], env)
        # Same arguments as this profile's normal Launcher; retain Popen solely to observe
        # the child status. Do not disable snapshot saving or inject artificial shutdown delay.
        argv = [str(sdk / 'emulator/emulator'), '-avd', 'kestrel-0', '-ports', '5580,5581',
                '-cores', '2', '-memory', '3072', '-gpu', 'host', '-accel', 'on',
                '-no-boot-anim', '-netdelay', 'none', '-netspeed', 'full', '-no-window',
                '-no-audio', '-feature', 'Vulkan', '-feature', 'GLDirectMem']
        report['argv'] = argv
        for n in range(1, 3):
            log(f'[{n+1}/3] Observe startup/shutdown cycle {n}')
            with (out / f'emulator-{n}.log').open('w') as writer:
                process = subprocess.Popen(argv, env=env, stdout=writer, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, start_new_session=True)
                pidfile = home / 'instances/0/emulator.pid'
                pidfile.write_text(str(process.pid))
                wait_for_adb(command, adb, 'emulator-5580', env, log, timeout=180)
                wait(10, 'allow guest to settle before normal snapshot shutdown')
                started = time.monotonic()
                stop = subprocess.Popen([str(cli), 'stop', '0'], env=env, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True)
                exit_at = None
                next_log = started + 10
                while stop.poll() is None:
                    if process.poll() is not None and exit_at is None:
                        exit_at = time.monotonic() - started
                    if time.monotonic() - started > 45:
                        raise RuntimeError('CLI stop exceeded observation budget')
                    if time.monotonic() >= next_log:
                        log(f'  shutdown elapsed={time.monotonic()-started:.1f}s; emulator exit={process.poll()}')
                        next_log += 10
                    time.sleep(0.05)
                output = stop.communicate()[0]
                (out / f'stop-{n}.txt').write_text(output)
                code = process.poll()
                if code is None:
                    raise RuntimeError('CLI stop returned while owned emulator still runs')
                rows.append({'cycle': n, 'pid': process.pid, 'emulator_exit_code': code,
                             'cli_exit_code': stop.returncode, 'seconds': time.monotonic()-started,
                             'first_observed_exit_seconds': exit_at, 'cli_output': output})
                log('  Observed: ' + json.dumps(rows[-1]))
                assert stop.returncode == 0, output
                process = None
                stop = None
            text = (out / f'emulator-{n}.log').read_text()
            rows[-1]['snapshot_save_ms'] = re.findall(r"Saving snapshot 'default_boot' using (\d+) ms", text)
            rows[-1]['snapshot_refused'] = 'Not saving state:' in text
            wait(3, 'allow ADB teardown before next cycle')
        report['status'] = 'completed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = str(exc)
        raise
    finally:
        if stop is not None and stop.poll() is None:
            stop.terminate()
            stop.wait(timeout=5)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        (out / 'report.json').write_text(json.dumps(report, indent=2))
        log('SUMMARY: ' + json.dumps(report))


if __name__ == '__main__':
    main()

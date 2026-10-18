#!/usr/bin/env python3
"""Observe manual snapshot eligibility while an original Vulkan resource probe is alive."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from run import command, log, ROOT
from transport import TransportBoot


def main():
    home = Path('/tmp/kestrel-perf-refresh-clean-11').resolve()
    output = ROOT / '.cocreate/research/vulkan-snapshot-default-01'
    output.mkdir(parents=True, exist_ok=False)
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk))
    settings = json.loads((home / 'instances/0/settings.json').read_text())
    assert settings['name'] == 'Fresh refresh probe', 'Not the disposable profile'
    local = ROOT / '.build/diagnostics/vulkan-probe'
    report = {'status': 'running', 'probe_sha256': hashlib.sha256(local.read_bytes()).hexdigest(),
              'snapshot_name': 'vk-probe-default-01'}
    boot = None
    process = None
    writer = None
    try:
        log('[1/5] Verify isolation and boot disposable guest with Vulkan enabled')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing device'
        (output / 'host-memory.txt').write_text(command(['vm_stat'], env))
        assert settings['vulkan'] is True
        boot = TransportBoot(home, sdk, settings, 'pipe', output, log)
        report['emulator_argv'] = boot.start(command, env)
        log('[2/5] Push and run bounded native probe; no unrelated apps stopped')
        remote = '/data/local/tmp/kestrel-vulkan-probe'
        command([adb, '-s', 'emulator-5580', 'push', local, remote], env)
        command([adb, '-s', 'emulator-5580', 'shell', 'chmod', '755', remote], env)
        logfile = output / 'probe.txt'
        writer = logfile.open('w')
        process = subprocess.Popen([str(adb), '-s', 'emulator-5580', 'shell', remote], env=env,
                                   stdout=writer, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 30
        while True:
            text = logfile.read_text()
            if 'PASS iteration=3 ' in text:
                break
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Vulkan probe did not initialize and verify fills: ' + text)
            time.sleep(1)
        print(text, flush=True)
        log('[3/5] Request named snapshot while Vulkan device and buffer exist')
        before = time.monotonic()
        saved = subprocess.run([str(adb), '-s', 'emulator-5580', 'emu', 'avd', 'snapshot', 'save',
                                report['snapshot_name']], env=env, capture_output=True, text=True, timeout=35)
        report['save_exit'] = saved.returncode
        report['save_seconds'] = time.monotonic() - before
        report['save_output'] = saved.stdout + saved.stderr
        (output / 'save-result.txt').write_text(report['save_output'])
        print(report['save_output'], flush=True)
        report['save_reported_success'] = saved.returncode == 0 and 'KO' not in report['save_output']
        # Do not load a potentially unsupported state just because the console returned OK.
        log('[4/5] Let bounded resource checks complete; observe errors after snapshot attempt')
        deadline = time.monotonic() + 110
        while process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Probe exceeded bounded completion deadline')
            log(f'  Vulkan probe active; remaining budget={remaining:.0f}s')
            try:
                process.wait(timeout=min(10, remaining))
            except subprocess.TimeoutExpired:
                pass
        writer.close()
        writer = None
        text = logfile.read_text()
        report['probe_exit'] = process.returncode
        report['verified_fill_lines'] = sum(line.startswith('PASS iteration=') for line in text.splitlines())
        if process.returncode != 0 or 'COMPLETE 90 verified GPU fills' not in text or 'FAIL' in text:
            raise RuntimeError('Vulkan execution failed; see probe.txt')
        report['status'] = 'completed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = str(exc)
        raise
    finally:
        log('[5/5] Stop owned VM and restore original host configuration')
        try:
            if boot is not None:
                boot.stop(command, env)
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if writer is not None:
                writer.close()
        except Exception as exc:
            report['cleanup_error'] = str(exc)
            report['status'] = 'failed'
        (output / 'report.json').write_text(json.dumps(report, indent=2))
        log('SUMMARY: ' + json.dumps(report))
    if report['status'] != 'completed':
        raise RuntimeError('Cleanup failed')


if __name__ == '__main__':
    main()

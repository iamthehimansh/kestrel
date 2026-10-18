#!/usr/bin/env python3
"""Bounded cold/warm startup probe using an isolated Kestrel home, never user data."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def log(message):
    print(time.strftime('[%H:%M:%S]'), message, flush=True)


def run(args, env, timeout=360):
    start = time.monotonic()
    log('$ ' + ' '.join(map(str, args)))
    process = subprocess.Popen(list(map(str, args)), env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    while True:
        try:
            output, _ = process.communicate(timeout=min(10, max(0.1, timeout - (time.monotonic() - start))))
            break
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - start
            log(f'  elapsed={elapsed:.0f}s; command running; remaining budget={max(0, timeout-elapsed):.0f}s')
            if elapsed >= timeout:
                process.kill()
                output, _ = process.communicate()
                print(output, flush=True)
                raise RuntimeError(f'command exceeded {timeout}s: {args}')
    print(output, end='' if output.endswith('\n') else '\n', flush=True)
    elapsed = time.monotonic() - start
    log(f'  finished in {elapsed:.2f}s, exit={process.returncode}')
    if process.returncode:
        raise RuntimeError(f'command failed: {args}')
    return {'seconds': elapsed, 'output': output}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, default=Path.home() / 'Library/Android/sdk')
    parser.add_argument('--vulkan', choices=['on', 'off'], default='on')
    parser.add_argument('--storage-gb', type=int, default=4)
    args = parser.parse_args()
    home = args.home.resolve()
    home.mkdir(parents=True, exist_ok=True)
    with (home / 'benchmark.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another probe owns this home; refusing duplicate execution')
        if (home / 'instances').exists():
            raise SystemExit('Use a fresh benchmark home; existing instances are never overwritten')
        env = dict(os.environ, KESTREL_HOME=str(home), ANDROID_SDK_ROOT=str(args.sdk))
        cli = args.cli.resolve()
        adb = args.sdk / 'platform-tools/adb'
        log('[1/5] Preflight: refusing occupied emulator port 5580')
        devices = run([adb, 'devices'], env, 15)['output']
        if 'emulator-5580' in devices:
            raise SystemExit('Port 5580 is already in use; no emulator changed')
        report = {'home': str(home), 'vulkan': args.vulkan, 'measurements': {}, 'status': 'running',
                  'cli_path': str(cli), 'cli_sha256': hashlib.sha256(cli.read_bytes()).hexdigest()}
        (home / 'host-memory.txt').write_text(subprocess.check_output(['vm_stat'], text=True))
        report['emulator_version'] = run([args.sdk / 'emulator/emulator', '-version'], env, 15)['output']
        report['settings'] = {'cpuCount': 2, 'memoryMB': 3072, 'width': 1280, 'height': 720,
                              'window': False, 'audio': False, 'dataPartitionGB': args.storage_gb,
                              'vulkan': args.vulkan == 'on'}
        run([cli, 'create', '--name', 'Startup probe', '--preset', 'low', '--resolution', 'tablet-1280x720'], env)
        run([cli, 'config', '0', '--set', json.dumps(report['settings'])], env)
        launched = False
        try:
            log('[2/5] Cold boot (includes first-run setup; not a steady-state metric)')
            launched = True
            report['measurements']['cold_boot'] = run([cli, 'start', '0', '--cold', '--wait'], env)
            report['guest_boot'] = run([adb, '-s', 'emulator-5580', 'shell', 'getprop sys.boot_completed'], env, 15)['output'].strip()
            if report['guest_boot'] != '1':
                raise RuntimeError('Android did not report boot completion')
            log('[3/5] Stop and capture snapshot outcome')
            report['measurements']['first_stop'] = run([cli, 'stop', '0'], env, 45)
            launched = False
            source = home / 'instances/0/emulator.log'
            (home / 'cold.log').write_bytes(source.read_bytes())
            avd = home / 'avd/kestrel-0.avd'
            saved_hardware = avd / 'snapshots/default_boot/hardware.ini'
            for name, path in [('cold-hardware.ini', avd / 'hardware-qemu.ini'),
                               ('cold-snapshot-hardware.ini', saved_hardware)]:
                if path.exists():
                    (home / name).write_bytes(path.read_bytes())
            log('[4/5] Warm start with unchanged settings')
            launched = True
            report['measurements']['warm_boot'] = run([cli, 'start', '0', '--wait'], env)
            log('[5/5] Stop probe emulator and preserve warm-start evidence')
            report['measurements']['second_stop'] = run([cli, 'stop', '0'], env, 45)
            launched = False
            (home / 'warm.log').write_bytes(source.read_bytes())
            report['snapshot_lines'] = {
                name: [line for line in (home / name).read_text(errors='replace').splitlines()
                       if 'snapshot' in line.lower() or 'boot completed' in line.lower()]
                for name in ['cold.log', 'warm.log']}
            report['status'] = 'completed'
        except Exception as exc:
            report['status'] = 'failed'
            report['error'] = str(exc)
            raise
        finally:
            if launched:
                log('Cleanup: stopping only the isolated probe instance')
                try:
                    run([cli, 'stop', '0'], env, 45)
                except Exception as exc:
                    log(f'Cleanup failed: {exc}')
            (home / 'report.json').write_text(json.dumps(report, indent=2))
            log(f'SUMMARY: {report["status"]}; evidence: {home / "report.json"}')
            for name, result in report['measurements'].items():
                log(f'  {name}: {result["seconds"]:.2f}s')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Windowed fixed-FBO GLES comparison on isolated profiles; never targets user instances."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import time
from run import command, log, wait, ROOT
from transport import TransportBoot

PACKAGE = 'org.kestrel.glesprobe'
TOOL = '/Applications/MuMuPlayer Pro.app/Contents/MacOS/mumutool'


def validate_report(data):
    if data.get('status') != 'completed':
        raise ValueError('GLES sample failed/interrupted: ' + str(data.get('error', data.get('status'))))
    for key, value in [('workload', 'gles-fixed-fbo-v1'), ('width', 1280), ('height', 720),
                       ('passes', 4), ('shader_iterations', 24), ('surface_width', 1280),
                       ('surface_height', 720)]:
        if data.get(key) != value:
            raise ValueError(f'Unexpected {key}: {data.get(key)} (expected {value})')
    for key in ['completed_draw', 'frame_start_intervals']:
        if data[key]['count'] < 10:
            raise ValueError('Insufficient samples: ' + key)
    if len(data.get('calibration_rgba', [])) != 4 or len(data.get('workload_readback_rgba', [])) != 3:
        raise ValueError('Missing render correctness checks')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--backend', choices=['kestrel', 'mumu'], required=True)
    parser.add_argument('--home', type=Path, default=Path('/tmp/kestrel-perf-storage6-03'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    env = dict(os.environ, ANDROID_SDK_ROOT=str(sdk))
    apk = ROOT / '.build/diagnostics/kestrel-glesprobe.apk'
    state = {'status': 'running', 'backend': args.backend, 'headless': False, 'samples': [],
             'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}
    reference = ROOT / '.cocreate/research/mumu-runtime'
    experiment = None
    mumu_owned = False
    serial = None

    def tool(*parts):
        data = json.loads(command([TOOL, *parts], env, 30))
        if data.get('errcode') != 0:
            raise RuntimeError(data)
        return data

    # Serialize our diagnostic runners across backends, without touching other processes.
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        log('[1/6] Check device isolation and host resources')
        devices = command([adb, 'devices'], env)
        if any(line.strip() and not line.startswith('List of') for line in devices.splitlines()):
            raise RuntimeError('Existing ADB device; refusing to affect it')
        (out / 'host-memory.txt').write_text(command(['vm_stat'], env))
        log('[2/6] Boot only selected diagnostic profile, windowed at 720p')
        if args.backend == 'kestrel':
            home = args.home.resolve()
            if not str(home).startswith('/private/tmp/kestrel-perf-'):
                raise RuntimeError('Not an isolated Kestrel profile')
            settings = json.loads((home / 'instances/0/settings.json').read_text())
            settings['window'] = True
            state['settings'] = settings
            experiment = TransportBoot(home, sdk, settings, 'pipe', out, log)
            state['emulator_argv'] = experiment.start(command, env)
            serial = 'emulator-5580'
        else:
            identity = json.loads((reference / 'instance.json').read_text())
            if identity['index'] != 1 or identity['name'] != 'Kestrel Diagnostic Baseline':
                raise RuntimeError('Unexpected MuMu diagnostic identity')
            current = tool('info', '1')['return']
            if current['bundle_path'] != identity['bundle_path'] or current['state'] != 'stopped':
                raise RuntimeError('MuMu diagnostic profile changed or is running')
            inventory = tool('info', 'all')['return']['results']
            if any(item['state'] != 'stopped' for item in inventory):
                raise RuntimeError('Another MuMu instance is active')
            original = json.loads((reference / 'original-config-before.json').read_text())
            if tool('config', '0') != original:
                raise RuntimeError('User MuMu profile changed; not altering it')
            config = tool('config', '1')['return']['callback']
            required = {'vmCpuCount': 2, 'vmMemoryOfMB': 3072, 'resolutionWidthHeight': '1280x720',
                        'resolutionDPI': 240, 'maxFpsLimit': 60, 'gpuFastMathEnable': False,
                        'dynamicFpsEnable': False, 'renderQualityEnable': False}
            for key, value in required.items():
                if config.get(key) != value:
                    raise RuntimeError(f'MuMu diagnostic setting changed: {key}')
            state['settings'] = required
            mumu_owned = True
            tool('open', '1')
            deadline = time.monotonic() + 180
            while True:
                info = tool('info', '1')['return']
                if info.get('state') == 'running' and info.get('adb_port'):
                    serial = '127.0.0.1:' + str(info['adb_port'])
                    print(command([adb, 'connect', serial], env), flush=True)
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('MuMu startup deadline exceeded')
                wait(10, 'MuMu diagnostic startup')
        def shell(*parts, **kw):
            return command([adb, '-s', serial, 'shell', *parts], env, **kw)
        deadline = time.monotonic() + 120
        while shell('getprop', 'sys.boot_completed').strip() != '1':
            if time.monotonic() >= deadline:
                raise RuntimeError('Android startup deadline exceeded')
            wait(10, 'Android boot completion')
        for prop in ['ro.build.version.sdk', 'ro.hardware.egl', 'ro.boot.hardware.gltransport']:
            state[prop] = shell('getprop', prop).strip()
        log('[3/6] Install or verify byte-identical GLES probe')
        if 'package:' + PACKAGE in shell('pm', 'list', 'packages', PACKAGE).splitlines():
            path = shell('pm', 'path', PACKAGE).strip()
            if not path.startswith('package:') or '\n' in path:
                raise RuntimeError('Unexpected APK layout')
            data = command([adb, '-s', serial, 'exec-out', 'cat', path[8:]], env, binary=True)
            if hashlib.sha256(data).hexdigest() != state['apk_sha256']:
                raise RuntimeError('Different probe already installed; refusing overwrite')
        else:
            print(command([adb, '-s', serial, 'install', '--no-incremental', str(apk)], env, 60), flush=True)
        wait(20, 'equal stabilization interval')
        log('[4/6] Run three synchronized GLES samples; no artificial input')
        for n in range(1, 4):
            shell('am', 'force-stop', PACKAGE)
            shell('run-as', PACKAGE, 'rm', '-f', 'files/report.json')
            shell('input', 'keyevent', 'KEYCODE_WAKEUP')
            shell('wm', 'dismiss-keyguard')
            start = time.monotonic()
            launch = shell('am', 'start', '-W', '-n', PACKAGE + '/.GLESActivity', '--ei', 'duration_seconds', '20')
            launch_seconds = time.monotonic() - start
            (out / f'launch-{n}.txt').write_text(launch)
            wait(5, f'GLES sample {n} warmup')
            focus = shell('dumpsys', 'window')
            (out / f'focus-{n}.txt').write_text(focus)
            focused = [line for line in focus.splitlines() if 'mCurrentFocus=' in line]
            png = command([adb, '-s', serial, 'exec-out', 'screencap', '-p'], env, binary=True)
            (out / f'sample-{n}.png').write_bytes(png)
            if not png.startswith(b'\x89PNG\r\n\x1a\n'):
                raise RuntimeError('Invalid screenshot')
            if not any(PACKAGE + '/' in line for line in focused) or 'Application Not Responding' in focus:
                raise RuntimeError('GLES probe is not unobstructed')
            wait(18, f'GLES sample {n} collecting completion timings')
            raw = shell('run-as', PACKAGE, 'cat', 'files/report.json')
            (out / f'sample-{n}.json').write_text(raw)
            data = json.loads(raw)
            validate_report(data)
            item = {'sample': n, 'launch_seconds': launch_seconds, 'renderer': data['renderer'],
                    'completed_draw': data['completed_draw'], 'frame_start_intervals': data['frame_start_intervals']}
            state['samples'].append(item)
            log('  Sample PASS: ' + json.dumps(item))
        log('[5/6] Capture graphics errors and display evidence')
        (out / 'errors.txt').write_text(shell('logcat', '-d', '-t', '200', '*:E'))
        (out / 'display.txt').write_text(shell('dumpsys', 'display'))
        shell('am', 'force-stop', PACKAGE)
        state['status'] = 'completed'
    except Exception as exc:
        state['status'] = 'failed'
        state['error'] = str(exc)
        raise
    finally:
        log('[6/6] Stop only owned VM; preserve evidence')
        try:
            if experiment is not None:
                experiment.stop(command, env)
            if mumu_owned:
                tool('close', '1')
                deadline = time.monotonic() + 30
                while tool('info', '1')['return']['state'] != 'stopped':
                    if time.monotonic() >= deadline:
                        raise RuntimeError('MuMu did not stop')
                    wait(2, 'MuMu shutdown')
                if tool('config', '0') != original:
                    raise RuntimeError('User MuMu profile configuration changed')
                state['original_user_config_unchanged'] = True
        except Exception as exc:
            state['status'] = 'failed'
            state['cleanup_error'] = str(exc)
        (out / 'summary.json').write_text(json.dumps(state, indent=2))
        log(f'SUMMARY: {state["status"]}; {len(state["samples"])} samples; {out}')
    if state['status'] != 'completed':
        raise RuntimeError('Cleanup failed')


if __name__ == '__main__':
    main()

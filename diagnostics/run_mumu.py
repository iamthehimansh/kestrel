#!/usr/bin/env python3
"""Bounded comparison on the separately created MuMu diagnostic instance only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
from run import command, log, wait, PACKAGE, ROOT

TOOL = '/Applications/MuMuPlayer Pro.app/Contents/MacOS/mumutool'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    adb = Path.home() / 'Library/Android/sdk/platform-tools/adb'
    apk = ROOT / '.build/diagnostics/kestrel-diagnostics.apk'
    reference = ROOT / '.cocreate/research/mumu-runtime'

    def tool(*parts):
        result = json.loads(command([TOOL, *parts], env))
        if result.get('errcode') != 0:
            raise RuntimeError(result)
        return result

    identity = json.loads((reference / 'instance.json').read_text())
    current = tool('info', str(identity['index']))['return']
    if current.get('name') != 'Kestrel Diagnostic Baseline' or current.get('bundle_path') != identity['bundle_path']:
        raise RuntimeError('Diagnostic identity mismatch; refusing to touch instance')
    if current.get('state') != 'running':
        raise RuntimeError('Diagnostic instance is not running')
    serial = '127.0.0.1:' + str(current['adb_port'])
    original_user = json.loads((reference / 'original-config-before.json').read_text())
    if tool('config', '0') != original_user:
        raise RuntimeError('Original user settings changed externally; refusing comparison')
    report = {'status': 'running', 'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
              'serial': serial, 'instance_index': identity['index'], 'samples': [],
              'headless': False, 'limitations': ['MuMu Android12 vs Kestrel Android16',
              'MuMu windowed vs earlier Kestrel headless; not proof of gameplay parity',
              'Small Canvas workload; not presented game FPS or host-to-photon latency']}
    rotation = {}
    try:
        log('[1/6] Verify diagnostic endpoint and preserve rotation settings')
        print(command([adb, 'connect', serial], env), flush=True)
        def shell(*parts, **kw):
            return command([adb, '-s', serial, 'shell', *parts], env, **kw)
        if shell('getprop', 'sys.boot_completed').strip() != '1':
            raise RuntimeError('Android not ready')
        for name in ['accelerometer_rotation', 'user_rotation']:
            rotation[name] = shell('settings', 'get', 'system', name).strip()
        report['original_rotation'] = rotation
        shell('settings', 'put', 'system', 'accelerometer_rotation', '0')
        shell('settings', 'put', 'system', 'user_rotation', '1')
        for prop in ['ro.build.version.release', 'ro.build.version.sdk', 'ro.hardware.egl', 'ro.hardware.vulkan']:
            report[prop] = shell('getprop', prop).strip()
        report['selected_settings'] = {k: v for k, v in tool('config', '1')['return']['callback'].items()
                                       if k in ['vmCpuCount', 'vmMemoryOfMB', 'resolutionWidthHeight',
                                                'resolutionDPI', 'maxFpsLimit', 'gpuFastMathEnable',
                                                'dynamicFpsEnable', 'renderQualityEnable']}
        (out / 'host-memory.txt').write_text(command(['vm_stat'], env))
        log('[2/6] Install exact diagnostic APK on diagnostic instance only')
        if 'package:' + PACKAGE in shell('pm', 'list', 'packages', PACKAGE).splitlines():
            path = shell('pm', 'path', PACKAGE).strip()
            if not path.startswith('package:') or '\n' in path:
                raise RuntimeError('Unexpected diagnostic package layout')
            data = command([adb, '-s', serial, 'exec-out', 'cat', path[8:]], env, binary=True)
            if hashlib.sha256(data).hexdigest() != report['apk_sha256']:
                raise RuntimeError('Diagnostic APK differs; not replacing it')
        else:
            print(command([adb, '-s', serial, 'install', str(apk)], env, 60), flush=True)
        log('[3/6] Stabilize and record display and process state')
        (out / 'display.txt').write_text(shell('dumpsys', 'display'))
        (out / 'processes-before.txt').write_text(shell('ps', '-A'))
        wait(20, 'bounded stabilization')
        log('[4/6] Run three identical 20-second diagnostic samples')
        for n in range(1, 4):
            shell('am', 'force-stop', PACKAGE)
            shell('run-as', PACKAGE, 'rm', '-f', 'files/report.json')
            shell('input', 'keyevent', 'KEYCODE_WAKEUP')
            shell('wm', 'dismiss-keyguard')
            started = time.monotonic()
            launch = shell('am', 'start', '-W', '-n', PACKAGE + '/.ProbeActivity', '--ei', 'duration_seconds', '20')
            elapsed = time.monotonic() - started
            (out / f'launch-{n}.txt').write_text(launch)
            wait(4, f'sample {n} warmup')
            focus = shell('dumpsys', 'window')
            (out / f'focus-{n}.txt').write_text(focus)
            focused = [line for line in focus.splitlines() if 'mCurrentFocus=' in line]
            if not any(PACKAGE + '/' in line for line in focused) or 'Application Not Responding' in focus:
                (out / f'interrupted-{n}.png').write_bytes(command([adb, '-s', serial, 'exec-out', 'screencap', '-p'], env, binary=True))
                raise RuntimeError('Diagnostic does not have unobstructed focus')
            shell('input', 'tap', '640', '360')
            image = command([adb, '-s', serial, 'exec-out', 'screencap', '-p'], env, binary=True)
            if not image.startswith(b'\x89PNG\r\n\x1a\n'):
                raise RuntimeError('Invalid screenshot')
            (out / f'sample-{n}.png').write_bytes(image)
            wait(19, f'sample {n} collecting frames')
            raw = shell('run-as', PACKAGE, 'cat', 'files/report.json')
            (out / f'sample-{n}.json').write_text(raw)
            data = json.loads(raw)
            if data['status'] != 'completed' or data['callback_intervals']['count'] < 10:
                raise RuntimeError('Incomplete sample')
            if 'error' in data['gles'] or data['touch_delivery_ages']['count'] < 2:
                raise RuntimeError('Graphics or touch probe failed')
            sample = {'report': f'sample-{n}.json', 'launch_seconds': elapsed,
                      'width': data['width'], 'height': data['height'], 'display_hz': data['display_hz'],
                      'callback_intervals': data['callback_intervals'], 'touch_delivery_ages': data['touch_delivery_ages']}
            report['samples'].append(sample)
            (out / f'gfxinfo-{n}.txt').write_text(shell('dumpsys', 'gfxinfo', PACKAGE, 'framestats'))
            log(f'  Sample {n} PASS: {sample}')
        log('[5/6] Record bounded errors and stop test app')
        (out / 'errors.txt').write_text(shell('logcat', '-d', '-t', '200', '*:E'))
        shell('am', 'force-stop', PACKAGE)
        report['status'] = 'completed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = str(exc)
        raise
    finally:
        log('[6/6] Restore diagnostic rotation; close only diagnostic instance; verify original profile')
        try:
            try:
                for name, value in rotation.items():
                    operation = ['delete', 'system', name] if value == 'null' else ['put', 'system', name, value]
                    command([adb, '-s', serial, 'shell', 'settings', *operation], env)
            finally:
                tool('close', str(identity['index']))
            deadline = time.monotonic() + 30
            while tool('info', str(identity['index']))['return']['state'] != 'stopped':
                if time.monotonic() > deadline:
                    raise RuntimeError('Diagnostic VM did not stop within 30 seconds')
                wait(2, 'diagnostic VM shutdown')
            if tool('config', '0') != original_user:
                raise RuntimeError('Original user configuration differs')
            report['original_user_config_unchanged'] = True
            report['diagnostic_vm_stopped'] = True
        except Exception as exc:
            report['status'] = 'failed'
            report['cleanup_error'] = str(exc)
        (out / 'summary.json').write_text(json.dumps(report, indent=2))
        log(f'SUMMARY: {report["status"]}; {len(report["samples"])} complete samples; {out}')
    if report['status'] != 'completed':
        raise RuntimeError('Cleanup verification failed')


if __name__ == '__main__':
    main()

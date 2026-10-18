#!/usr/bin/env python3
"""Run three bounded probes on an explicitly selected isolated Kestrel test profile."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from transport import TransportBoot
from refresh import RefreshPreferences

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'org.kestrel.diagnostics'


def log(message):
    print(time.strftime('[%H:%M:%S]'), message, flush=True)


def command(args, env, timeout=30, binary=False):
    started = time.monotonic()
    process = subprocess.Popen(list(map(str, args)), env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=not binary)
    while True:
        try:
            out, err = process.communicate(timeout=min(10, max(0.1, timeout - (time.monotonic() - started))))
            break
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            log(f'  {Path(args[0]).name} running: {elapsed:.0f}s; remaining budget {max(0, timeout-elapsed):.0f}s')
            if elapsed >= timeout:
                process.kill()
                process.communicate()
                raise RuntimeError(f'Command timed out: {args}')
    if process.returncode:
        raise RuntimeError(f'Command failed ({process.returncode}): {args}\n{err!r}\n{out!r}')
    return out


def wait(seconds, purpose):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        left = until - time.monotonic()
        log(f'  {purpose}; {left:.0f}s remaining')
        time.sleep(min(10, left))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cold', action='store_true')
    parser.add_argument('--transport', choices=['pipe', 'asg'], help='Isolated cold-boot transport experiment; snapshots disabled')
    parser.add_argument('--refresh-hz', type=int, choices=[30, 60, 90, 120, 144, 165, 240])
    parser.add_argument('--guest-refresh-preferences', action='store_true', help='Temporarily set and restore Android min/peak refresh preferences')
    parser.add_argument('--peak-only', action='store_true', help='Leave Android minimum refresh preference untouched')
    args = parser.parse_args()
    if args.peak_only and not args.guest_refresh_preferences:
        parser.error('--peak-only requires --guest-refresh-preferences')
    if args.guest_refresh_preferences and args.refresh_hz is None:
        parser.error('--guest-refresh-preferences requires --refresh-hz')
    if args.refresh_hz is not None and not args.transport:
        parser.error('--refresh-hz requires --transport for isolated configuration restoration')
    home = args.home.resolve()
    if not str(home).startswith('/private/tmp/kestrel-perf-'):
        raise RuntimeError('Only isolated /tmp/kestrel-perf-* profiles may be used')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    with (home / 'runtime-probe.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sdk = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Library/Android/sdk')))
        env = dict(os.environ, KESTREL_HOME=str(home), ANDROID_SDK_ROOT=str(sdk))
        cli = (ROOT / '.build/debug/kestrel').resolve()
        adb = sdk / 'platform-tools/adb'
        apk = ROOT / '.build/diagnostics/kestrel-diagnostics.apk'
        serial = 'emulator-5580'
        settings = json.loads((home / 'instances/0/settings.json').read_text())
        state = {'status': 'running', 'settings': settings, 'samples': [],
                 'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                 'cli_sha256': hashlib.sha256(cli.read_bytes()).hexdigest(),
                 'headless': not settings['window'], 'cold_boot': args.cold or bool(args.transport),
                 'requested_transport': args.transport, 'requested_refresh_hz': args.refresh_hz}
        log('[1/6] Check device ownership and record host memory')
        devices = command([adb, 'devices'], env)
        if any(line.strip() and not line.startswith('List of') for line in devices.splitlines()):
            raise RuntimeError('An ADB device is already connected; refusing to affect it')
        (output / 'host-memory.txt').write_text(command(['vm_stat'], env))
        owned = False
        experiment = None
        preferences = None
        try:
            log('[2/6] Boot only the isolated profile')
            if args.transport:
                experiment = TransportBoot(home, sdk, settings, args.transport, output, log, refresh_hz=args.refresh_hz)
                state['emulator_argv'] = experiment.start(command, env)
                owned = True
            else:
                owned = True
                boot = [cli, 'start', '0', '--wait']
                if args.cold:
                    boot.append('--cold')
                print(command(boot, env, 360), flush=True)
            def shell(*parts, **kwargs):
                return command([adb, '-s', serial, 'shell', *parts], env, **kwargs)
            if shell('getprop', 'sys.boot_completed').strip() != '1':
                raise RuntimeError('Guest not booted')
            if args.guest_refresh_preferences:
                (output / 'display-before-preferences.txt').write_text(shell('dumpsys', 'display'))
                preferences = RefreshPreferences(shell)
                preferences.apply(args.refresh_hz, peak_only=args.peak_only)
                state['original_refresh_preferences'] = preferences.original
                state['peak_only'] = args.peak_only
                log('  Temporary Android refresh preferences applied (peak-only=' + str(args.peak_only) + ')')
            log('[3/6] Install original diagnostic APK; existing packages are preserved')
            installed = shell('pm', 'list', 'packages', PACKAGE).splitlines()
            if 'package:' + PACKAGE in installed:
                package_path = shell('pm', 'path', PACKAGE).strip()
                if not package_path.startswith('package:') or '\n' in package_path:
                    raise RuntimeError('Unexpected installed diagnostic APK layout')
                installed_bytes = command([adb, '-s', serial, 'exec-out', 'cat', package_path[8:]], env, binary=True)
                if hashlib.sha256(installed_bytes).hexdigest() != state['apk_sha256']:
                    raise RuntimeError('Installed diagnostic APK differs; refusing to replace it')
                log('  Reusing byte-identical diagnostic APK')
            else:
                print(command([adb, '-s', serial, 'install', str(apk)], env, 60), flush=True)
            for prop in ['ro.build.version.release', 'ro.hardware.egl', 'ro.hardware.vulkan',
                         'ro.boot.hardware.gltransport', 'ro.surface_flinger.game_default_frame_rate_override']:
                state[prop] = shell('getprop', prop).strip()
            (output / 'display.txt').write_text(shell('dumpsys', 'display'))
            (output / 'processes-before.txt').write_text(shell('ps', '-A'))
            wait(20, 'same bounded stabilization interval')
            log('[4/6] Run three 20-second samples, preserving raw reports and screenshots')
            for sample in range(1, 4):
                shell('am', 'force-stop', PACKAGE)
                shell('run-as', PACKAGE, 'rm', '-f', 'files/report.json')
                shell('input', 'keyevent', 'KEYCODE_WAKEUP')
                shell('wm', 'dismiss-keyguard')
                before = time.monotonic()
                launched = shell('am', 'start', '-W', '-n', PACKAGE + '/.ProbeActivity', '--ei', 'duration_seconds', '20')
                launch_seconds = time.monotonic() - before
                (output / f'launch-{sample}.txt').write_text(launched)
                wait(4, f'sample {sample} warmup')
                focused = shell('dumpsys', 'window', 'displays')
                (output / f'focus-{sample}.txt').write_text(focused)
                focus_lines = [line for line in focused.splitlines() if 'mCurrentFocus=' in line]
                if not any(PACKAGE + '/' in line for line in focus_lines) or 'Application Not Responding' in focused:
                    screenshot = command([adb, '-s', serial, 'exec-out', 'screencap', '-p'], env, binary=True)
                    (output / f'interrupted-{sample}.png').write_bytes(screenshot)
                    raise RuntimeError('Diagnostic app does not have unobstructed focus; refusing to inject touch')
                shell('input', 'tap', str(settings['width']//2), str(settings['height']//2))
                png = command([adb, '-s', serial, 'exec-out', 'screencap', '-p'], env, binary=True)
                if not png.startswith(b'\x89PNG\r\n\x1a\n'):
                    raise RuntimeError('Invalid screenshot')
                (output / f'sample-{sample}.png').write_bytes(png)
                wait(19, f'sample {sample} collecting callback intervals')
                raw = shell('run-as', PACKAGE, 'cat', 'files/report.json')
                (output / f'sample-{sample}.json').write_text(raw)
                report = json.loads(raw)
                if report.get('status') != 'completed' or report['callback_intervals']['count'] < 10:
                    raise RuntimeError(f'Incomplete diagnostic sample {sample}: {report}')
                if args.refresh_hz is not None and abs(report['display_hz'] - args.refresh_hz) > 0.5:
                    raise RuntimeError(f'Refresh request not active: {report["display_hz"]} Hz')
                if 'error' in report['gles']:
                    raise RuntimeError('GLES capability probe failed')
                if report['touch_delivery_ages']['count'] < 2:
                    raise RuntimeError('Injected touch not received')
                state['samples'].append({'report': f'sample-{sample}.json', 'launch_seconds': launch_seconds,
                                         'callback_intervals': report['callback_intervals'],
                                         'touch_delivery_ages': report['touch_delivery_ages']})
                (output / f'gfxinfo-{sample}.txt').write_text(shell('dumpsys', 'gfxinfo', PACKAGE, 'framestats'))
                log(f'  sample {sample} PASS: {state["samples"][-1]}')
            log('[5/6] Collect bounded error log and stop the diagnostic app')
            (output / 'errors.txt').write_text(shell('logcat', '-d', '-t', '200', '*:E'))
            shell('am', 'force-stop', PACKAGE)
            state['status'] = 'completed'
        except Exception as exc:
            state['status'] = 'failed'
            state['error'] = str(exc)
            if owned:
                for name, query in [('failure-anr.txt', ['dumpsys', 'activity', 'lastanr']),
                                    ('failure-errors.txt', ['logcat', '-d', '-t', '200', '*:E'])]:
                    try:
                        (output / name).write_text(command([adb, '-s', serial, 'shell'] + query, env, 20))
                    except Exception as capture_error:
                        log(f'  Failure evidence unavailable: {capture_error}')
            raise
        finally:
            log('[6/6] Restore guest preferences and stop owned emulator; retain evidence')
            if preferences is not None:
                state['original_refresh_preferences'] = preferences.original
                try:
                    preferences.restore()
                    state['refresh_preferences_restored'] = True
                except Exception as exc:
                    state['restoration_error'] = str(exc)
                    state['status'] = 'failed'
            if experiment is not None or owned:
                try:
                    if experiment is not None:
                        experiment.stop(command, env)
                    else:
                        print(command([cli, 'stop', '0'], env, 45), flush=True)
                except Exception as exc:
                    state['cleanup_error'] = str(exc)
                    state['status'] = 'failed'
            (output / 'summary.json').write_text(json.dumps(state, indent=2))
            log(f'SUMMARY: {state["status"]}; {len(state["samples"])} completed samples; {output}')
        if state['status'] != 'completed':
            raise RuntimeError('Probe cleanup failed; see summary')


if __name__ == '__main__':
    main()

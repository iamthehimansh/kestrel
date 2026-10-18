#!/usr/bin/env python3
"""Run the native Swift client against an owned JWT-only loopback emulator."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import time
from run import command, log, ROOT
from transport import TransportBoot
from product_boot import ProductBoot


def read_response(process, timeout):
    pending = bytearray()
    deadline = time.monotonic() + timeout
    next_log = time.monotonic() + 10
    while b'\n' not in pending:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Native response deadline exceeded')
        ready, _, _ = select.select([process.stdout], [], [], min(1, remaining))
        if ready:
            data = os.read(process.stdout.fileno(), 4096)
            if not data:
                raise RuntimeError('Native process closed response pipe')
            pending.extend(data)
            if len(pending) > 16384:
                raise RuntimeError('Native response exceeded limit')
        if time.monotonic() >= next_log:
            log(f'  Waiting for native result; {remaining:.0f}s budget remaining')
            next_log = time.monotonic() + 10
    result = json.loads(pending.split(b'\n', 1)[0])
    if not isinstance(result, dict):
        raise RuntimeError('Invalid native response')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--player', action='store_true', help='Run bounded native Metal window diagnostic')
    parser.add_argument('--product-launcher', type=Path, help='Use compiled actual Launcher adapter instead of experimental launch')
    parser.add_argument('--native-registration', action='store_true', help='Native signer publishes/revokes its own public key')
    args = parser.parse_args()
    if args.native_registration and args.player:
        parser.error('--native-registration currently tests the stream client, not the player')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    home = Path('/tmp/kestrel-perf-storage6-03').resolve()
    settings = json.loads((home / 'instances/0/settings.json').read_text())
    assert settings['name'] == 'Startup probe'
    env = dict(os.environ)
    native = boot = public_file = None
    report = {'status': 'running'}
    try:
        log('[1/5] Verify isolation; start native identity over private pipes')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing device'
        for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
            with socket.socket(family) as sock:
                sock.bind((address, 8556))
        (out / 'memory.txt').write_text(command(['vm_stat'], env))
        executable = 'NativePlayerProbe' if args.player else 'NativeStreamProbe'
        native = subprocess.Popen([str(ROOT / '.build/debug' / executable)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, bufsize=0)
        identity = read_response(native, 10)
        kid = identity['key_id']
        if not re.fullmatch(r'[a-f0-9-]{36}', kid):
            raise RuntimeError('Invalid public key identifier')
        if any('d' in key for key in identity['jwks']['keys']):
            raise RuntimeError('Unexpected private key export')
        policy = out / 'access.json'
        policy.write_text(json.dumps(identity['policy']))
        log('[2/5] Boot JWT-protected emulator and verify loopback listener')
        if args.product_launcher:
            boot = ProductBoot(args.product_launcher, home, sdk, policy, out, log)
            report['uses_product_launcher'] = True
        else:
            boot = TransportBoot(home, sdk, settings, 'pipe', out, log,
                                 grpc_port=8556, grpc_allowlist=policy)
        boot.start(command, env)
        listeners = command(['/usr/sbin/lsof', '-nP', '-a', '-p', str(boot.process.pid),
                             '-iTCP:8556', '-sTCP:LISTEN'], env)
        (out / 'listener.txt').write_text(listeners)
        rows = [line for line in listeners.splitlines() if 'LISTEN' in line]
        assert rows and all('127.0.0.1:8556' in r or '[::1]:8556' in r for r in rows), 'Non-loopback listener'
        host = '::1' if any('[::1]:8556' in row for row in rows) else '127.0.0.1'
        match = re.search(r'Scanning (.+?) for jwk keys', (out / 'emulator.log').read_text())
        if not match:
            raise RuntimeError('Missing public JWK discovery metadata')
        directory = Path(match.group(1)).resolve(strict=True)
        assert directory.is_dir() and directory.stat().st_uid == os.getuid(), 'Unexpected directory owner'
        if not args.native_registration:
            public_file = directory / ('kestrel-native-probe-' + kid + '.jwk')
            fd = os.open(public_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as file:
                json.dump(identity['jwks'], file)
        log('[3/5] Launch known animation; run native auth, stream-stop and cancellation checks')
        package = 'org.kestrel.diagnostics'
        command([adb, '-s', 'emulator-5580', 'shell', 'am', 'force-stop', package], env)
        command([adb, '-s', 'emulator-5580', 'shell', 'run-as', package, 'rm', '-f', 'files/report.json'], env)
        command([adb, '-s', 'emulator-5580', 'shell', 'am', 'start', '-W', '-n',
                 package + '/.ProbeActivity', '--ei', 'duration_seconds', '60'], env)
        log('  Allowing 3s for the animation to replace its launch splash')
        time.sleep(3)
        expected_home = None
        if args.player:
            resolved = command([adb, '-s', 'emulator-5580', 'shell', 'cmd', 'package',
                                'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN',
                                '-c', 'android.intent.category.HOME'], env)
            components = [line.strip() for line in resolved.splitlines() if '/' in line]
            if len(components) != 1:
                raise RuntimeError('Could not identify default Android launcher')
            expected_home = components[0].split('/', 1)[0]
            report['expected_launcher_package'] = expected_home
        native.stdin.write(json.dumps({'host': host, 'port': 8556,
                                      'sdk': str(sdk), 'serial': 'emulator-5580',
                                      'registration_directory': str(directory) if args.native_registration else None,
                                      'screenshot': str(out / 'native-frame.png')}).encode() + b'\n')
        result = read_response(native, 35)
        if args.player and result.get('event') == 'capture_window':
            window_id = result.get('window_id')
            if type(window_id) is not int or window_id <= 0:
                raise RuntimeError('Invalid diagnostic window identifier')
            report['capture_event'] = result
            try:
                command(['/usr/sbin/screencapture', '-x', '-o', '-l', str(window_id),
                         str(out / 'player-window.png')], env, 5)
                report['window_capture_saved'] = (out / 'player-window.png').is_file()
            except RuntimeError:
                report['window_capture_saved'] = False
            result = read_response(native, 15)
        report['native'] = result
        if result.get('status') != 'completed':
            raise RuntimeError('Native check failed; safe result retained')
        native.stdin.close()
        native.wait(timeout=5)
        if native.returncode != 0:
            raise RuntimeError('Native executable returned failure')
        log('[4/5] Verify result and stop diagnostic animation')
        if args.player:
            assert result['changed_pixels'] is True and result['stale_frame_rejected'] is True
            assert result['submitted_frames'] >= 60 and result['received_frames'] >= 60
            assert result['cancellation_seconds'] < 2
            assert result['home_command_completed'] is True
            assert result['screenshot_action_completed'] is True
            screenshot = (out / 'native-frame.png').read_bytes()
            if not screenshot.startswith(b'\x89PNG\r\n\x1a\n'):
                raise RuntimeError('Screenshot action did not save a valid PNG header')
            import struct
            if struct.unpack('>II', screenshot[16:24]) != (1280, 720):
                raise RuntimeError('Screenshot action saved incorrect guest dimensions')
            report['guest_screenshot_verified'] = True
            assert result['pointer_down_up_forwarded'] is True
            guest_report = command([adb, '-s', 'emulator-5580', 'shell', 'run-as', package,
                                    'cat', 'files/report.json'], env, 10)
            (out / 'guest-pointer-report.json').write_text(guest_report)
            guest = json.loads(guest_report)
            events = guest.get('touches', [])
            actions = [event.get('action') for event in events]
            if result.get('pointer_drag_forwarded'):
                if len(actions) < 3 or actions[0] != 0 or actions[-1] != 1 or any(action != 2 for action in actions[1:-1]):
                    raise RuntimeError('Guest did not receive one down, movement and one release in order')
                report['guest_drag_verified'] = True
            elif actions != [0, 1]:
                raise RuntimeError('Guest did not receive exactly one pointer down/up pair')
            if any(event.get('pointer_count') != 1 for event in events):
                raise RuntimeError('Unexpected multitouch count in isolated pointer test')
            report['guest_pointer_verified'] = True
            deadline = time.monotonic() + 5
            while True:
                focus = command([adb, '-s', 'emulator-5580', 'shell', 'dumpsys', 'window', 'displays'], env, 5)
                focus_lines = [line for line in focus.splitlines() if 'mCurrentFocus=' in line]
                if any(expected_home + '/' in line for line in focus_lines):
                    (out / 'home-focus.txt').write_text('\n'.join(focus_lines))
                    report['home_action_verified'] = True
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('Home command exited successfully but launcher is not focused')
                time.sleep(0.25)
            png = command([adb, '-s', 'emulator-5580', 'exec-out', 'screencap', '-p'], env, binary=True)
            if not png.startswith(b'\x89PNG\r\n\x1a\n'):
                raise RuntimeError('Invalid post-Home screenshot')
            (out / 'after-home.png').write_bytes(png)
        else:
            assert result['bounded_stream_frames'] == 90 and result['wrong_audience_rejected'] is True
            assert result['request_after_cancel'] is True and result['cancellation_seconds'] < 2
            if args.native_registration:
                assert result['native_registration_used'] is True and result['revoked_token_rejected'] is True
                assert result['revocation_seconds'] < 15
                assert not (directory / ('kestrel-' + kid + '.jwk')).exists(), 'Own public key remains'
                report['native_revocation_verified'] = True
        command([adb, '-s', 'emulator-5580', 'shell', 'am', 'force-stop', package], env)
        report['status'] = 'completed'
        report['loopback_listener_verified'] = True
    except Exception as error:
        report['error_type'] = type(error).__name__
        # Native transport errors are sanitized; never retain RPC metadata or private keys.
        log('Native interoperability failed: ' + type(error).__name__)
    finally:
        log('[5/5] Revoke public key, stop native process and owned emulator')
        try:
            if public_file is not None:
                public_file.unlink(missing_ok=True)
        except Exception as error:
            report['status'] = 'failed'; report['key_cleanup_error'] = type(error).__name__
        if native is not None and native.poll() is None:
            native.terminate()
            try:
                native.wait(timeout=3)
            except subprocess.TimeoutExpired:
                native.kill(); native.wait(timeout=3)
        if boot is not None:
            try:
                boot.stop(command, env)
            except Exception as error:
                report['status'] = 'failed'; report['vm_cleanup_error'] = type(error).__name__
        if report['status'] == 'running':
            report['status'] = 'failed'
        (out / 'report.json').write_text(json.dumps(report, indent=2))
        log('SUMMARY: ' + json.dumps(report))
    if report['status'] != 'completed':
        raise RuntimeError('Native stream check failed; see safe report')


if __name__ == '__main__':
    main()

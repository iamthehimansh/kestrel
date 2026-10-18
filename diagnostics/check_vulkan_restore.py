#!/usr/bin/env python3
"""Test experimental VulkanSnapshots on disposable guest resources, never user sessions."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import time
from run import command, log, ROOT
from transport import TransportBoot
from reconnect import wait_for_adb


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--enable-vulkan-snapshots', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--restart-host', action='store_true', help='Restore in a new emulator process, not in place')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    home = Path('/tmp/kestrel-perf-refresh-clean-11').resolve()
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    env = dict(os.environ)
    local = ROOT / '.build/diagnostics/vulkan-probe'
    settings = json.loads((home / 'instances/0/settings.json').read_text())
    assert settings['name'] == 'Fresh refresh probe' and settings['vulkan'] is True
    report = {'status': 'running', 'flag_enabled': args.enable_vulkan_snapshots,
              'probe_sha256': hashlib.sha256(local.read_bytes()).hexdigest()}
    boot = None
    snapshot = 'vk-restore-' + str(time.time_ns())
    remote = '/data/local/tmp/kestrel-vulkan-probe'
    logfile = '/data/local/tmp/kestrel-vk-snapshot.log'
    trigger = '/data/local/tmp/kestrel-vk-continue'

    def shell(*parts):
        return command([adb, '-s', 'emulator-5580', 'shell', *parts], env, 15)

    def wait_for(needle, timeout):
        start = time.monotonic()
        next_log = start
        while time.monotonic() - start < timeout:
            text = shell('cat', logfile)
            if 'FAIL' in text:
                raise RuntimeError('Vulkan resource verification failed: ' + text)
            if needle in text:
                return text
            if time.monotonic() >= next_log:
                log(f'  Waiting for {needle}; elapsed={time.monotonic()-start:.0f}s')
                next_log = time.monotonic() + 10
            time.sleep(1)
        raise RuntimeError('Probe deadline exceeded waiting for ' + needle)

    def console(operation):
        before = time.monotonic()
        text = command([adb, '-s', 'emulator-5580', 'emu', 'avd', 'snapshot', operation, snapshot], env, 45)
        report[operation + '_seconds'] = time.monotonic() - before
        report[operation + '_output'] = text
        (out / (operation + '.txt')).write_text(text)
        print(text, flush=True)
        return not any(line.startswith('KO') for line in text.splitlines())

    try:
        log('[1/6] Check isolation; boot with explicitly selected Vulkan snapshot flag')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing device'
        (out / 'host-memory.txt').write_text(command(['vm_stat'], env))
        boot = TransportBoot(home, sdk, settings, 'pipe', out, log,
                             vulkan_snapshots=args.enable_vulkan_snapshots)
        report['emulator_argv'] = boot.start(command, env)
        log('[2/6] Run detached bounded probe to a GPU-resource checkpoint')
        command([adb, '-s', 'emulator-5580', 'push', local, remote], env)
        shell('chmod', '755', remote)
        shell('rm', '-f', trigger)
        pid = shell('sh', '-c', "'nohup " + remote + ' --snapshot-probe >' + logfile + " 2>&1 </dev/null & echo $!'" ).strip()
        if not pid.isdigit():
            raise RuntimeError('Unexpected probe process response: ' + pid)
        report['guest_probe_pid'] = int(pid)
        text = wait_for('READY snapshot checkpoint', 30)
        (out / 'checkpoint.txt').write_text(text)
        log('[3/6] Save live Vulkan state; preserve failure as a result')
        saved = console('save')
        report['snapshot_saved'] = saved
        if not saved:
            shell('touch', trigger)
            text = wait_for('COMPLETE 20 verified GPU fills', 40)
            (out / 'rejected-save-probe.txt').write_text(text)
            report['outcome'] = 'snapshot_rejected_resources_still_healthy'
        else:
            log('[4/6] Let resources change and be destroyed before restoring')
            shell('touch', trigger)
            text = wait_for('COMPLETE 20 verified GPU fills', 40)
            (out / 'before-load.txt').write_text(text)
            assert 'RETAINED iteration=4 pattern=4b450003' in text
            log('[5/6] Load snapshot, prove checkpoint rollback and verify retained data before new GPU work')
            if args.restart_host:
                report['first_host_pid'] = boot.process.pid
                boot.stop(command, env)
                assert boot.process.poll() is not None, 'Original host process still alive'
                deadline = time.monotonic() + 15
                while 'emulator-5580' in command([adb, 'devices'], env, 5):
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Old test ADB transport did not disappear')
                    time.sleep(1)
                restarted = out / 'restarted'
                restarted.mkdir()
                boot = TransportBoot(home, sdk, settings, 'pipe', restarted, log,
                                     vulkan_snapshots=args.enable_vulkan_snapshots)
                before = time.monotonic()
                report['restart_argv'] = boot.start(command, env, snapshot=snapshot)
                report['restart_seconds'] = time.monotonic() - before
                report['second_host_pid'] = boot.process.pid
                assert report['first_host_pid'] != report['second_host_pid']
                restart_log = (restarted / 'emulator.log').read_text()
                assert "Successfully loaded snapshot '" + snapshot + "'" in restart_log, 'Snapshot load not confirmed'
            elif not console('load'):
                raise RuntimeError('Snapshot save succeeded but load was rejected')
            wait_for_adb(command, adb, 'emulator-5580', env, log, timeout=30)
            image = command([adb, '-s', 'emulator-5580', 'exec-out', 'screencap', '-p'], env, 15, binary=True)
            if not image.startswith(b'\x89PNG\r\n\x1a\n'):
                raise RuntimeError('Invalid post-restore screenshot')
            (out / 'after-load.png').write_bytes(image)
            text = wait_for('READY snapshot checkpoint', 30)
            (out / 'after-load-checkpoint.txt').write_text(text)
            if 'COMPLETE' in text or 'CONTINUE' in text:
                raise RuntimeError('Guest log did not roll back to saved checkpoint')
            shell('touch', trigger)
            text = wait_for('COMPLETE 20 verified GPU fills', 45)
            (out / 'after-load-complete.txt').write_text(text)
            assert 'RETAINED iteration=4 pattern=4b450003' in text, 'Restored memory not verified before overwrite'
            assert text.count('PASS iteration=') == 20
            report['outcome'] = ('host_restart_verified_for_bounded_buffer_probe' if args.restart_host
                                 else 'live_restore_verified_for_bounded_buffer_probe')
        report['status'] = 'completed'
    except Exception as exc:
        report['status'] = 'failed'
        report['error'] = str(exc)
        raise
    finally:
        log('[6/6] Stop owned VM and restore exact AVD configuration')
        if boot is not None:
            try:
                boot.stop(command, env)
            except Exception as exc:
                report['status'] = 'failed'
                report['cleanup_error'] = str(exc)
        (out / 'report.json').write_text(json.dumps(report, indent=2))
        log('SUMMARY: ' + json.dumps(report))
    if report['status'] != 'completed':
        raise RuntimeError('Cleanup failed')


if __name__ == '__main__':
    main()

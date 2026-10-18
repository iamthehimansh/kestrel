"""Isolated pipe/ASG experiment launcher. No changes to Kestrel product defaults."""
from pathlib import Path
import os
import subprocess
import time


def configured_transport(original, transport):
    if transport not in ('pipe', 'asg'):
        raise ValueError('Unsupported experimental transport')
    lines = original.decode('utf-8').splitlines()
    lines = [line for line in lines if line.split('=', 1)[0].strip() != 'hw.gltransport']
    return ('\n'.join(lines + ['hw.gltransport=' + transport]) + '\n').encode('utf-8')


def configured_refresh(original, hz):
    if type(hz) is not int or hz not in (30, 60, 90, 120, 144, 165, 240):
        raise ValueError('Unsupported experimental refresh rate')
    lines = original.decode('utf-8').splitlines()
    lines = [line for line in lines if line.split('=', 1)[0].strip() != 'hw.lcd.vsync']
    return ('\n'.join(lines + ['hw.lcd.vsync=' + str(hz)]) + '\n').encode('utf-8')


class TransportBoot:
    def __init__(self, home, sdk, settings, transport, output, log, refresh_hz=None, vulkan_snapshots=False,
                 grpc_port=None, grpc_allowlist=None, disable_async_swap=False):
        self.config = home / 'avd/kestrel-0.avd/config.ini'
        self.original = self.config.read_bytes()
        self.process = None
        self.output = None
        self.log = log
        self.home = home
        self.sdk = sdk
        self.settings = settings
        self.transport = transport
        self.destination = output
        self.refresh_hz = refresh_hz
        if type(vulkan_snapshots) is not bool:
            raise ValueError('vulkan_snapshots must be a boolean')
        if vulkan_snapshots and not settings.get('vulkan'):
            raise ValueError('Vulkan snapshot experiment requires Vulkan')
        self.vulkan_snapshots = vulkan_snapshots
        if (grpc_port is None) != (grpc_allowlist is None):
            raise ValueError('gRPC requires both a port and an explicit authenticated allowlist')
        if grpc_port is not None and (type(grpc_port) is not int or not 1024 <= grpc_port <= 65535):
            raise ValueError('Invalid diagnostic gRPC port')
        self.grpc_port = grpc_port
        self.grpc_allowlist = grpc_allowlist
        if type(disable_async_swap) is not bool:
            raise ValueError('disable_async_swap must be a boolean')
        self.disable_async_swap = disable_async_swap

    def start(self, command, env, snapshot=None):
        if not str(self.home.resolve()).startswith('/private/tmp/kestrel-perf-'):
            raise RuntimeError('Experimental transport only permitted on isolated profiles')
        s = self.settings
        argv = [str(self.sdk / 'emulator/emulator'), '-avd', 'kestrel-0', '-ports', '5580,5581',
                '-cores', str(s['cpuCount']), '-memory', str(s['memoryMB']), '-gpu', s['gpuMode'],
                '-accel', 'on', '-no-boot-anim', '-netdelay', 'none', '-netspeed', 'full',
                '-no-snapshot-save', '-feature', 'Vulkan' if s['vulkan'] else '-Vulkan']
        if snapshot is None:
            argv += ['-no-snapshot-load']
        else:
            if not snapshot.startswith('vk-restore-') or not snapshot[len('vk-restore-'):].isdigit():
                raise ValueError('Only generated Vulkan diagnostic snapshots may be loaded')
            if not (self.home / 'avd/kestrel-0.avd/snapshots' / snapshot / 'snapshot.pb').is_file():
                raise ValueError('Diagnostic snapshot metadata missing')
            argv += ['-snapshot', snapshot]
        if s['vulkan']:
            argv += ['-feature', 'GLDirectMem']
        if self.vulkan_snapshots:
            argv += ['-feature', 'VulkanSnapshots']
        if self.disable_async_swap:
            argv += ['-feature', '-GLAsyncSwap']
        if self.grpc_port is not None:
            argv += ['-grpc', str(self.grpc_port), '-grpc-use-jwt',
                     '-grpc-allowlist', str(self.grpc_allowlist)]
        if not s['window']:
            argv += ['-no-window']
        if not s['audio']:
            argv += ['-no-audio']
        for field, prop in [('deviceBrand', 'brand'), ('deviceModel', 'model')]:
            if s.get(field):
                argv += ['-prop', 'ro.product.' + prop + '=' + s[field]]
        configured = configured_transport(self.original, self.transport)
        if self.refresh_hz is not None:
            configured = configured_refresh(configured, self.refresh_hz)
        (self.destination / 'avd-config-before.ini').write_bytes(self.original)
        (self.destination / 'avd-config-experiment.ini').write_bytes(configured)
        self.config.write_bytes(configured)
        self.output = (self.destination / 'emulator.log').open('w')
        self.process = subprocess.Popen(argv, env=dict(env, ANDROID_AVD_HOME=str(self.home / 'avd'),
                                       ANDROID_EMU_VK_ICD='moltenvk'),
                                       stdout=self.output, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
        self.log('  Owned experimental emulator pid=' + str(self.process.pid))
        started = time.monotonic()
        next_log = started
        adb = self.sdk / 'platform-tools/adb'
        while time.monotonic() - started < 300:
            if self.process.poll() is not None:
                raise RuntimeError('Experimental emulator exited; inspect emulator.log')
            try:
                ready = command([adb, '-s', 'emulator-5580', 'shell', 'getprop', 'sys.boot_completed'], env, 5).strip()
                if ready == '1':
                    observed = command([adb, '-s', 'emulator-5580', 'shell', 'getprop',
                                        'ro.boot.hardware.gltransport'], env, 5).strip()
                    if observed != self.transport:
                        raise ValueError(f'Transport not activated: requested {self.transport}, observed {observed}')
                    self.log(f'  Guest ready after {time.monotonic()-started:.1f}s; transport={observed}')
                    return argv
            except RuntimeError:
                pass  # ADB may be disconnected during boot; deadline remains bounded.
            if time.monotonic() >= next_log:
                self.log(f'  Boot elapsed={time.monotonic()-started:.0f}s; waiting for Android')
                next_log = time.monotonic() + 10
            time.sleep(1)
        raise RuntimeError('Experimental boot exceeded 300 seconds')

    def stop(self, command, env):
        try:
            if self.process is not None and self.process.poll() is None:
                try:
                    command([self.sdk / 'platform-tools/adb', '-s', 'emulator-5580', 'emu', 'kill'], env, 10)
                except RuntimeError as exc:
                    self.log('  Graceful shutdown request failed: ' + str(exc))
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait(timeout=5)
        finally:
            if self.output is not None:
                self.output.close()
            self.config.write_bytes(self.original)
            if self.config.read_bytes() != self.original:
                raise RuntimeError('Failed to restore experiment configuration')
            self.log('  Original AVD config restored; no snapshots saved during experiment')

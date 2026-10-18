"""Controller for the diagnostic adapter that exercises KestrelCore.Launcher directly."""
import json
from pathlib import Path
import select
import subprocess
import os
import time
from types import SimpleNamespace


class ProductBoot:
    def __init__(self, executable, home, sdk, policy, output, log):
        self.executable = Path(executable).resolve()
        self.home, self.sdk, self.policy = home, sdk, policy
        self.output, self.log = output, log
        self.controller = None
        self.process = None
        self.logfile = None
        self.pending = bytearray()
        self.error_file = None

    def response(self, timeout):
        deadline = time.monotonic() + timeout
        next_log = time.monotonic() + 10
        while b'\n' not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Product launcher response deadline exceeded')
            ready, _, _ = select.select([self.controller.stdout], [], [], min(1, remaining))
            if ready:
                data = os.read(self.controller.stdout.fileno(), 4096)
                if not data:
                    raise RuntimeError('Product launcher response pipe closed')
                self.pending.extend(data)
                if len(self.pending) > 16384:
                    raise RuntimeError('Product launcher response too large')
            if time.monotonic() >= next_log:
                self.log(f'  Product launcher active; {remaining:.0f}s response budget remaining')
                next_log = time.monotonic() + 10
        line, _, self.pending = self.pending.partition(b'\n')
        return json.loads(line)

    def start(self, command, env):
        if not str(self.home.resolve()).startswith('/private/tmp/kestrel-perf-'):
            raise RuntimeError('Product launch probe requires isolated test profile')
        self.error_file = (self.output / 'product-launcher-stderr.txt').open('w')
        self.controller = subprocess.Popen([str(self.executable), str(self.home), str(self.sdk), str(self.policy)],
                                           env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=self.error_file, bufsize=0)
        result = self.response(200)
        (self.output / 'product-launch-response.json').write_text(json.dumps(result, indent=2))
        if result.get('status') != 'ready' or type(result.get('pid')) is not int:
            raise RuntimeError('Product launcher failed; no authenticated connection attempted')
        expected_log = self.home / 'instances/0/emulator.log'
        if Path(result['log']).resolve() != expected_log.resolve():
            raise RuntimeError('Unexpected product log path')
        self.logfile = expected_log
        self.process = SimpleNamespace(pid=result['pid'])
        (self.output / 'product-launch.json').write_text(json.dumps(result, indent=2))
        self.capture_log()
        self.log('  Product launcher reports ready; PID=' + str(result['pid']))

    def capture_log(self):
        if self.logfile is not None and self.logfile.exists():
            (self.output / 'emulator.log').write_bytes(self.logfile.read_bytes())

    def stop(self, command, env):
        if self.controller is None:
            return
        try:
            if self.controller.poll() is None:
                self.controller.stdin.write(b'stop\n')
                self.controller.stdin.close()
                result = self.response(45)
                (self.output / 'product-stop.json').write_text(json.dumps(result, indent=2))
                if result.get('status') != 'stopped':
                    raise RuntimeError('Product launcher cleanup not confirmed')
            self.controller.wait(timeout=5)
            if self.controller.returncode != 0:
                raise RuntimeError('Product launcher reported failure')
        finally:
            self.capture_log()
            if self.controller.stdin and not self.controller.stdin.closed:
                self.controller.stdin.close()  # EOF asks the adapter to stop its owned VM.
            if self.controller.poll() is None:
                try:
                    self.controller.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    # Do not kill an unrelated VM from stale pidfile information.
                    raise RuntimeError('Product launcher cleanup still running; explicit inspection required')
            if self.controller.stdout:
                self.controller.stdout.close()
            if self.error_file is not None:
                self.error_file.close()
            (self.output / 'product-launcher-exit.json').write_text(
                json.dumps({'exit_code': self.controller.returncode}))

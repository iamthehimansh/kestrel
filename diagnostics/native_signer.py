"""Private pipe client for the native signer interoperability test. Never log responses."""
import json
import os
from pathlib import Path
import select
import subprocess
import time


class NativeSigner:
    def __init__(self, executable):
        self.process = subprocess.Popen([str(Path(executable).resolve())], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.pending = bytearray()
        try:
            public = self.request({'operation': 'public'})
            self.jwks = public['jwks']
            self.policy = public['policy']
            self.key_id = public['key_id']
            for key in self.jwks['keys']:
                if 'd' in key:
                    raise RuntimeError('Signer returned private material')
        except Exception:
            self.close()
            raise RuntimeError('Native signer initialization failed') from None

    def request(self, request):
        if self.process.poll() is not None:
            raise RuntimeError('Native signer exited')
        self.process.stdin.write(json.dumps(request).encode() + b'\n')
        deadline = time.monotonic() + 5
        while b'\n' not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Native signer response deadline exceeded')
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            if not ready:
                raise RuntimeError('Native signer response deadline exceeded')
            data = os.read(self.process.stdout.fileno(), 4096)
            if not data:
                raise RuntimeError('Native signer pipe closed')
            self.pending.extend(data)
            if len(self.pending) > 16384:
                raise RuntimeError('Native signer response exceeded size budget')
        line, _, remainder = self.pending.partition(b'\n')
        self.pending = bytearray(remainder)
        try:
            response = json.loads(line)
        except Exception:
            raise RuntimeError('Invalid native signer response') from None
        if 'error' in response:
            raise RuntimeError('Native signer rejected request')
        return response

    def metadata(self, method, expired=False, wrong=False):
        mode = 'expired' if expired else 'wrong' if wrong else 'valid'
        response = self.request({'operation': 'token', 'method': method, 'mode': mode})
        token = response.get('token')
        if not isinstance(token, str) or len(token) > 4096 or token.count('.') != 2:
            raise RuntimeError('Invalid native token shape')
        return (('authorization', 'Bearer ' + token),)

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        if self.process.stdout:
            self.process.stdout.close()
        self.pending.clear()

#!/usr/bin/env python3
"""Authenticated loopback framebuffer diagnostic; private signing material stays in RAM."""
import argparse
import fcntl
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import socket
import statistics
import struct
import subprocess
import sys
import time
import uuid
import zlib

from run import command, log, ROOT
from transport import TransportBoot
from auth_checks import is_auth_rejection
from shared_frame import SharedFrame
from native_signer import NativeSigner

PREFIX = '/android.emulation.control.EmulatorController/'
ISSUER = 'kestrel-local-stream-probe'
PORT = 8556


def save_rgba_png(path, width, height, pixels):
    if width <= 0 or height <= 0 or len(pixels) != width * height * 4:
        raise ValueError('Invalid RGBA frame dimensions/length')
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + pixels[y*width*4:(y+1)*width*4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    import grpc
    import grpc_tools
    import jwt
    from cryptography.hazmat.primitives.asymmetric import ec
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--delivery', choices=['inline', 'mmap'], default='inline')
    parser.add_argument('--native-signer', type=Path, help='Diagnostic pipe adapter for the production CryptoKit signer')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    lock = (ROOT / '.build/diagnostics/runtime.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sdk = Path.home() / 'Library/Android/sdk'
    adb = sdk / 'platform-tools/adb'
    home = Path('/tmp/kestrel-perf-storage6-03').resolve()
    settings = json.loads((home / 'instances/0/settings.json').read_text())
    assert settings['name'] == 'Startup probe' and settings['width'] == 1280
    env = dict(os.environ)
    report = {'status': 'running', 'port': PORT, 'samples': [], 'authentication_checks': {}}
    boot = None
    channel = None
    public_file = None
    shared = None
    native = None
    report['delivery'] = args.delivery
    report['signer'] = 'CryptoKit' if args.native_signer else 'PyJWT'
    try:
        log('[1/6] Check isolation and generate bindings from installed emulator protocol')
        devices = command([adb, 'devices'], env)
        assert not any(l.strip() and not l.startswith('List of') for l in devices.splitlines()), 'Existing ADB device'
        for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
            with socket.socket(family) as test:
                test.bind((address, PORT))
        (out / 'host-memory.txt').write_text(command(['vm_stat'], env))
        proto = sdk / 'emulator/lib/emulator_controller.proto'
        report['protocol_sha256'] = hashlib.sha256(proto.read_bytes()).hexdigest()
        generated = out / 'bindings'
        generated.mkdir()
        include = Path(grpc_tools.__file__).parent / '_proto'
        command([sys.executable, '-m', 'grpc_tools.protoc', '-I'+str(proto.parent), '-I'+str(include),
                 '--python_out='+str(generated), '--grpc_python_out='+str(generated), str(proto)], env)
        sys.path.insert(0, str(generated))
        pb = importlib.import_module('emulator_controller_pb2')
        api = importlib.import_module('emulator_controller_pb2_grpc')
        allowlist = out / 'access.json'
        if args.native_signer:
            native = NativeSigner(args.native_signer)
            allowlist.write_text(json.dumps(native.policy))
        else:
            allowlist.write_text(json.dumps({'unprotected': [], 'allowlist': [
                {'iss': ISSUER, 'allowed': [], 'protected': [PREFIX+'getScreenshot', PREFIX+'streamScreenshot']}]}))
        log('[2/6] Boot disposable VM with JWT required; verify actual listener binding')
        boot = TransportBoot(home, sdk, settings, 'pipe', out, log,
                             grpc_port=PORT, grpc_allowlist=allowlist)
        report['argv'] = boot.start(command, env)
        sockets = command(['/usr/sbin/lsof', '-nP', '-a', '-p', str(boot.process.pid),
                           '-iTCP:'+str(PORT), '-sTCP:LISTEN'], env)
        (out / 'listener.txt').write_text(sockets)
        rows = [line for line in sockets.splitlines() if 'LISTEN' in line]
        assert rows and all(('127.0.0.1:'+str(PORT) in line or '[::1]:'+str(PORT) in line) for line in rows), 'Non-loopback listener'
        target = '[::1]:'+str(PORT) if any('[::1]' in line for line in rows) else '127.0.0.1:'+str(PORT)
        report['loopback_listener_verified'] = True
        channel = grpc.secure_channel(target, grpc.local_channel_credentials(),
                                      options=[('grpc.max_receive_message_length', 32*1024*1024)])
        grpc.channel_ready_future(channel).result(timeout=10)
        client = api.EmulatorControllerStub(channel)
        request = pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=1280, height=720)
        def denied(label, metadata):
            try:
                client.getScreenshot(request, metadata=metadata, timeout=5)
            except grpc.RpcError as error:
                detail = error.details() or ''
                detail = re.sub(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[redacted token]', detail)
                detail = re.sub(r'(?i)bearer\s+\S+', 'Bearer [redacted]', detail)
                report.setdefault('negative_token_responses', {})[label] = {
                    'status': error.code().name, 'detail_redacted': detail[:800]}
                if not is_auth_rejection(label, error.code().name, detail):
                    raise RuntimeError(label + ' returned unexpected status ' + error.code().name)
                report['authentication_checks'][label] = error.code().name
                return
            raise RuntimeError(label + ' request was improperly accepted')
        denied('missing_token', ())
        log('[3/6] Publish only an ephemeral public key; private key/token never logged or saved')
        # The emulator reports its own public-key discovery folder in its startup log.
        report['stage'] = 'public_key_discovery'
        deadline = time.monotonic() + 5
        match = None
        while time.monotonic() < deadline:
            text = (out / 'emulator.log').read_text()
            match = re.search(r'Scanning (.+?) for jwk keys', text)
            if match:
                break
            time.sleep(0.25)
        if not match:
            raise RuntimeError('Public key discovery directory not present in emulator log')
        directory = Path(match.group(1)).resolve(strict=True)
        if not directory.is_dir() or directory.stat().st_uid != os.getuid():
            raise RuntimeError('Public key discovery directory has unexpected owner/type')
        if native is not None:
            kid = native.key_id
            public_set = native.jwks
        else:
            private = ec.generate_private_key(ec.SECP256R1())
            public = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(private.public_key()))
            kid = str(uuid.uuid4())
            public.update(kid=kid, use='sig', alg='ES256')
            public_set = {'keys': [public]}
        public_file = directory / ('kestrel-probe-'+kid+'.jwk')
        with public_file.open('x') as file:
            json.dump(public_set, file)
        os.chmod(public_file, 0o600)
        def metadata(method, expired=False, wrong=False):
            if native is not None:
                return native.metadata(method, expired=expired, wrong=wrong)
            now = int(time.time())
            claims = {'iss': ISSUER, 'iat': now-120 if expired else now-1,
                      'exp': now-60 if expired else now+120,
                      'aud': [PREFIX+('unrelatedMethod' if wrong else method)]}
            token = jwt.encode(claims, private, algorithm='ES256', headers={'kid': kid, 'typ': None})
            return (('authorization', 'Bearer '+token),)
        # Wait only for the new public key to be observed; do not weaken authentication.
        report['stage'] = 'authenticated_screenshot'
        deadline = time.monotonic()+10
        first = None
        while time.monotonic()<deadline:
            try:
                first = client.getScreenshot(request, metadata=metadata('getScreenshot'), timeout=3)
                break
            except grpc.RpcError as error:
                report['last_rpc_status'] = error.code().name
                # Retain diagnostic text, never compact JWTs or Authorization headers.
                detail = error.details() or ''
                detail = re.sub(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[redacted token]', detail)
                detail = re.sub(r'(?i)bearer\s+\S+', 'Bearer [redacted]', detail)
                report['last_rpc_detail_redacted'] = detail[:800]
                if error.code() not in (grpc.StatusCode.UNAUTHENTICATED, grpc.StatusCode.PERMISSION_DENIED):
                    raise RuntimeError('Authenticated request failed: '+error.code().name)
                time.sleep(0.25)
        if first is None:
            raise RuntimeError('Public key not accepted before deadline')
        report['stage'] = 'negative_token_checks'
        denied('expired_token', metadata('getScreenshot', expired=True))
        denied('wrong_audience', metadata('getScreenshot', wrong=True))
        report['authenticated_screenshot'] = True
        save_rgba_png(out/'first-frame.png', first.format.width, first.format.height, first.image)
        log('[4/6] Run original animation; measure three bounded ' + args.delivery + ' RGBA streams')
        stream_request = pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=1280, height=720)
        if args.delivery == 'mmap':
            shared = SharedFrame(out, 1280, 720)
            stream_request.transport.channel = pb.ImageTransport.MMAP
            stream_request.transport.handle = shared.uri
        report['stage'] = 'stream_measurement'
        package = 'org.kestrel.diagnostics'
        if 'package:'+package not in command([adb, '-s', 'emulator-5580', 'shell', 'pm', 'list', 'packages', package], env).splitlines():
            raise RuntimeError('Expected diagnostic app not installed; no arbitrary workload selected')
        for n in range(1,4):
            command([adb, '-s', 'emulator-5580', 'shell', 'am', 'force-stop', package], env)
            command([adb, '-s', 'emulator-5580', 'shell', 'am', 'start', '-W', '-n',
                     package+'/.ProbeActivity', '--ei', 'duration_seconds', '20'], env)
            time.sleep(2)
            stream = client.streamScreenshot(stream_request, metadata=metadata('streamScreenshot'), timeout=12)
            count=total=changed_reads=0
            last_pixels = None
            cpu_begin = time.process_time()
            sequences=[]
            ages=[]
            begin=time.monotonic()
            last=None
            try:
                for frame in stream:
                    if frame.format.width !=1280 or frame.format.height!=720:
                        raise RuntimeError('Unexpected streamed RGBA dimensions')
                    if shared is None:
                        if len(frame.image) !=1280*720*4:
                            raise RuntimeError('Unexpected inline frame length')
                        last_pixels = frame.image
                    else:
                        if frame.image:
                            raise RuntimeError('MMAP request fell back to inline pixels')
                        last_pixels, changed = shared.capture()
                        changed_reads += int(changed)
                    if sequences and frame.seq <= sequences[-1]:
                        raise RuntimeError('Frame sequence did not advance')
                    count+=1; total+=len(frame.image); sequences.append(frame.seq); last=frame
                    ages.append(time.time()*1e6-frame.timestampUs)
                    if time.monotonic()-begin>=5:
                        break
            finally:
                stream.cancel()
            elapsed=time.monotonic()-begin
            if count<10 or last is None:
                raise RuntimeError('Insufficient streamed frames')
            cpu_seconds = time.process_time() - cpu_begin
            save_rgba_png(out/f'raw-{n}.png',last.format.width,last.format.height,last_pixels)
            row={'sample':n,'frames':count,'seconds':elapsed,'received_frames_per_second':count/elapsed,
                 'client_cpu_seconds':cpu_seconds,'changed_between_consecutive_mmap_reads':changed_reads,
                 'payload_MiB_per_second':total/elapsed/2**20,'first_seq':sequences[0],'last_seq':sequences[-1],
                 'median_estimated_frame_age_ms':statistics.median(ages)/1000,
                 'limits':'Receive rate and estimated same-host timestamp age, not display latency; no frame presentation yet.'}
            report['samples'].append(row);log('  '+json.dumps(row))
        log('[5/6] Stop diagnostic workload; retain frame and authentication evidence')
        command([adb,'-s','emulator-5580','shell','am','force-stop',package],env)
        report['status']='completed'
    except Exception as error:
        report['status']='failed'
        # Do not serialize RPC details or request metadata: they may contain a token.
        report['error_type']=type(error).__name__
        log('Probe failed ('+type(error).__name__+'); no credentials logged')
        # RPC exceptions can include metadata; never propagate them to a traceback.
    finally:
        log('[6/6] Revoke own public key, close channel, stop owned VM and restore config')
        for cleanup in [lambda: public_file.unlink(missing_ok=True) if public_file is not None else None,
                        lambda: channel.close() if channel is not None else None,
                        lambda: boot.stop(command, env) if boot is not None else None,
                        lambda: shared.close() if shared is not None else None,
                        lambda: native.close() if native is not None else None]:
            try:
                cleanup()
            except Exception as error:
                report['status'] = 'failed'
                report.setdefault('cleanup_errors', []).append(type(error).__name__)
        (out/'report.json').write_text(json.dumps(report,indent=2))
        log('SUMMARY: '+report['status']+'; '+str(len(report['samples']))+' raw stream samples; '+str(out))
    if report['status']!='completed':
        raise RuntimeError('Streaming cleanup failed')


if __name__=='__main__':
    main()

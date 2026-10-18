#!/usr/bin/env python3
"""Build the EmuDetectProbe APK with installed SDK tools, no Gradle (same
proven pattern as mumu-rea/diagnostics/build.py). Timestamped progress lines."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

WORK = Path('/tmp/kestrel-research')
OUT = WORK / 'out'
SDK = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Library/Android/sdk')))
BUILD_TOOLS = SDK / 'build-tools/35.0.0'
ANDROID = SDK / 'platforms/android-36/android.jar'
SOURCE = WORK / 'ProbeActivity.java'
MANIFEST = WORK / 'AndroidManifest.xml'
ARTIFACT = OUT / 'kestrel-emudetect.apk'

TOTAL = 8

def log(step, message):
    print(time.strftime('[%H:%M:%S]'), f'[{step}/{TOTAL}]', message, flush=True)

def run(step, name, args, env):
    started = time.monotonic()
    log(step, f'RUN {name}: {" ".join(map(str, args))[:140]}')
    proc = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True)
    elapsed = time.monotonic() - started
    if proc.returncode != 0:
        print(proc.stdout[-3000:], file=sys.stderr)
        print(proc.stderr[-3000:], file=sys.stderr)
        raise RuntimeError(f'{name} failed rc={proc.returncode} after {elapsed:.1f}s')
    log(step, f'OK {name} ({elapsed:.1f}s)')
    return proc

def main():
    t0 = time.monotonic()
    log(1, f'Preflight: source={SOURCE} manifest={MANIFEST} android.jar exists={ANDROID.exists()}')
    if not SOURCE.exists() or not MANIFEST.exists() or not ANDROID.exists():
        raise SystemExit('missing inputs')
    if not BUILD_TOOLS.exists():
        raise SystemExit(f'missing build-tools at {BUILD_TOOLS}')
    # Locate a JDK
    candidates = [Path(os.environ['JAVA_HOME'])] if os.environ.get('JAVA_HOME') else []
    detected = subprocess.run(['/usr/libexec/java_home'], capture_output=True, text=True)
    if detected.returncode == 0:
        candidates.append(Path(detected.stdout.strip()))
    candidates += [Path('/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home'),
                   Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home')]
    java = next((p for p in candidates if (p / 'bin/javac').is_file()), None)
    if java is None:
        raise SystemExit('no JDK found')
    env = dict(os.environ, JAVA_HOME=str(java), PATH=str(java / 'bin') + ':' + os.environ.get('PATH', ''))
    log(2, f'Using JDK at {java}')
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='emudetect-', dir=OUT) as directory:
        work = Path(directory)
        classes, dex = work / 'classes', work / 'dex'
        classes.mkdir(); dex.mkdir()
        run(3, 'javac (dalvik-targeted compile)', [java / 'bin/javac', '-source', '8', '-target', '8',
             '-classpath', ANDROID, '-d', classes, SOURCE], env)
        run(4, 'd8 (dalvik bytecode)', [BUILD_TOOLS / 'd8', '--min-api', '26', '--lib', ANDROID,
             '--output', dex, *sorted(str(p) for p in classes.rglob('*.class'))], env)
        unsigned = work / 'unsigned.apk'
        run(5, 'aapt (package manifest)', [BUILD_TOOLS / 'aapt', 'package', '-f', '-M', MANIFEST,
             '-I', ANDROID, '-F', unsigned], env)
        with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as apk:
            apk.write(dex / 'classes.dex', 'classes.dex')
        aligned = work / 'aligned.apk'
        run(6, 'zipalign', [BUILD_TOOLS / 'zipalign', '-f', '4', unsigned, aligned], env)
        # apksig requires the ZIP to end exactly at its EOCD record; the append-mode
        # zip step can leave stray trailing bytes that apksigner would then fold
        # into its signature digest. Trim the input to its true end BEFORE signing.
        pre = bytearray(aligned.read_bytes())
        eocd = pre.rfind(b'PK\x05\x06')
        if eocd < 0:
            raise SystemExit('no EOCD in aligned APK')
        comment_len = int.from_bytes(pre[eocd + 20:eocd + 22], 'little')
        true_end = eocd + 22 + comment_len
        if len(pre) > true_end:
            log(6, f'Truncating {len(pre) - true_end} stray byte(s) past EOCD before signing')
            aligned.write_bytes(bytes(pre[:true_end]))
        signing = work / 'signing.jks'
        run(7, 'keytool (disposable local-test identity)', [java / 'bin/keytool', '-genkeypair', '-noprompt',
             '-keystore', signing, '-storetype', 'JKS', '-storepass', 'android', '-keypass', 'android',
             '-alias', 'probe', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '30',
             '-dname', 'CN=Kestrel Stealth Test Only'], env)
        run(8, 'apksigner (sign)', [BUILD_TOOLS / 'apksigner', 'sign', '--ks', signing,
             '--ks-key-alias', 'probe', '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
             '--out', ARTIFACT, aligned], env)
        verify = subprocess.run([str(BUILD_TOOLS / 'apksigner'), 'verify', '--verbose', str(ARTIFACT)],
                                capture_output=True, text=True)
        if verify.returncode != 0:
            print(verify.stdout, verify.stderr, file=sys.stderr)
            raise SystemExit('apksigner verify FAILED')
        with zipfile.ZipFile(ARTIFACT) as archive:
            assert 'classes.dex' in archive.namelist(), 'classes.dex missing'
        manifest = {
            'apk': str(ARTIFACT),
            'sha256': hashlib.sha256(ARTIFACT.read_bytes()).hexdigest(),
            'source_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            'signing': 'Disposable local-test identity.',
            'apksigner_verify': 'passed',
        }
        (OUT / 'build.json').write_text(json.dumps(manifest, indent=2))
    print(time.strftime('[%H:%M:%S]'), f'SUMMARY: BUILD_OK apk={ARTIFACT} sha256={manifest["sha256"][:16]}… '
          f'verify=passed total={time.monotonic()-t0:.1f}s', flush=True)

if __name__ == '__main__':
    main()

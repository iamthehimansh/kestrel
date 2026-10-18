#!/usr/bin/env python3
"""Build a local-only diagnostic APK with installed SDK tools, without Gradle downloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SDK = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Library/Android/sdk')))
BUILD_TOOLS = SDK / 'build-tools/35.0.0'
ANDROID = SDK / 'platforms/android-36/android.jar'
OUT = ROOT / '.build/diagnostics'


def log(message):
    print(time.strftime('[%H:%M:%S]'), message, flush=True)


def step(number, name, args, env):
    started = time.monotonic()
    log(f'[{number}/7] {name}')
    process = subprocess.Popen(list(map(str, args)), env=env)
    while True:
        try:
            code = process.wait(timeout=10)
            break
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            log(f'[{number}/7] Running: {name}; elapsed={elapsed:.0f}s')
            if elapsed > 180:
                process.kill()
                process.wait()
                raise RuntimeError(f'{name} timed out')
    log(f'[{number}/7] Exit={code}, elapsed={time.monotonic()-started:.1f}s')
    if code:
        raise RuntimeError(f'{name} failed with exit {code}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--gles', action='store_true', help='Build separate fixed-size GLES probe')
    args = parser.parse_args()
    source = ROOT / ('diagnostics/src/org/kestrel/glesprobe/GLESActivity.java' if args.gles
                     else 'diagnostics/src/org/kestrel/diagnostics/ProbeActivity.java')
    manifest_path = ROOT / ('diagnostics/GLESManifest.xml' if args.gles else 'diagnostics/AndroidManifest.xml')
    artifact = 'kestrel-glesprobe' if args.gles else 'kestrel-diagnostics'
    if not ANDROID.exists():
        raise RuntimeError(f'Android platform not installed: {ANDROID}')
    candidates = [Path(os.environ['JAVA_HOME'])] if os.environ.get('JAVA_HOME') else []
    detected = subprocess.run(['/usr/libexec/java_home'], capture_output=True, text=True)
    if detected.returncode == 0:
        candidates.append(Path(detected.stdout.strip()))
    candidates += [Path('/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home'),
                   Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home')]
    java = next((p for p in candidates if (p / 'bin/javac').is_file()), None)
    if java is None:
        raise RuntimeError('A JDK is required; set JAVA_HOME to an installed JDK')
    env = dict(os.environ, JAVA_HOME=str(java), PATH=str(java / 'bin') + ':' + os.environ.get('PATH', ''))
    OUT.mkdir(parents=True, exist_ok=True)
    # The disposable signing identity is for this probe only, not a release credential.
    # Keep it in the temporary build directory and remove it automatically afterward.
    with tempfile.TemporaryDirectory(prefix='probe-', dir=OUT) as directory:
        work = Path(directory)
        classes, dex = work / 'classes', work / 'dex'
        classes.mkdir()
        dex.mkdir()
        step(1, 'Compile diagnostic Java source', [java / 'bin/javac', '-source', '8', '-target', '8',
             '-classpath', ANDROID, '-d', classes, source,
             *([] if args.gles else [source.with_name('KeyboardActivity.java'), source.with_name('EGLSwapActivity.java')])], env)
        step(2, 'Compile Dalvik bytecode', [BUILD_TOOLS / 'd8', '--min-api', '26', '--lib', ANDROID,
             '--output', dex, *sorted(classes.rglob('*.class'))], env)
        unsigned = work / 'unsigned.apk'
        staged_manifest = work / 'AndroidManifest.xml'
        staged_manifest.write_bytes(manifest_path.read_bytes())
        step(3, 'Package manifest', [BUILD_TOOLS / 'aapt', 'package', '-f', '-M',
             staged_manifest, '-I', ANDROID, '-F', unsigned], env)
        with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as apk:
            apk.write(dex / 'classes.dex', 'classes.dex')
        aligned = work / 'aligned.apk'
        step(4, 'Align APK', [BUILD_TOOLS / 'zipalign', '-f', '4', unsigned, aligned], env)
        signing = work / 'disposable-debug.jks'
        step(5, 'Create disposable test signing identity', [java / 'bin/keytool', '-genkeypair', '-noprompt',
             '-keystore', signing, '-storetype', 'JKS', '-storepass', 'android', '-keypass', 'android',
             '-alias', 'probe', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '30',
             '-dname', 'CN=Kestrel Diagnostic Test Only'], env)
        apk = OUT / (artifact + '.apk')
        step(6, 'Sign local diagnostic APK', [BUILD_TOOLS / 'apksigner', 'sign', '--ks', signing,
             '--ks-key-alias', 'probe', '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
             '--out', apk, aligned], env)
        step(7, 'Verify APK signature and packaged contents', [BUILD_TOOLS / 'apksigner', 'verify',
             '--verbose', apk], env)
        with zipfile.ZipFile(apk) as archive:
            assert {'classes.dex', 'AndroidManifest.xml'}.issubset(archive.namelist())
        manifest = {'apk': str(apk), 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                    'sdk': str(SDK), 'build_tools': '35.0.0',
                    'signing': 'Disposable local-test identity; rebuilding requires uninstall/reinstall.'}
        (OUT / ('gles-build.json' if args.gles else 'build.json')).write_text(json.dumps(manifest, indent=2))
        log(f'SUMMARY: build and signature verification passed; APK={apk}; runtime validation remains')


if __name__ == '__main__':
    main()

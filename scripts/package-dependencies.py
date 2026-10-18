#!/usr/bin/env python3
"""Copy pinned dependency notices and Swift resource bundles into an app staging tree."""
import argparse
import hashlib
import json
import re
import shutil
import time
from pathlib import Path


def package_dependencies(root, binaries, resources):
    pins = json.loads((root / 'Package.resolved').read_text())['pins']
    notices = resources / 'ThirdPartyNotices'
    notices.mkdir(parents=True, exist_ok=False)
    manifest = []
    for index, pin in enumerate(pins, 1):
        started = time.monotonic()
        identity = pin['identity']
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*', identity):
            raise ValueError('Unsafe dependency identity')
        print(time.strftime('[%H:%M:%S]'), f'[{index}/{len(pins)}] Collecting notices: {identity}', flush=True)
        checkout = root / '.build/checkouts' / identity
        if not checkout.is_dir():
            raise ValueError(f'Missing pinned checkout: {identity}')
        files = sorted(p for p in checkout.rglob('*') if p.is_file() and not p.is_symlink()
                       and p.name.upper().startswith(('LICENSE', 'NOTICE', 'COPYING'))
                       and '.git' not in p.relative_to(checkout).parts)
        if not any(p.parent == checkout and p.name.upper().startswith(('LICENSE', 'COPYING')) for p in files):
            raise ValueError(f'Missing root license: {identity}')
        entries = []
        for source in files:
            relative = source.relative_to(checkout)
            destination = notices / identity / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            entries.append({'path': str(relative), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
        manifest.append({'identity': identity, 'source': pin['location'], 'state': pin['state'], 'notices': entries})
        print(time.strftime('[%H:%M:%S]'), f'[{index}/{len(pins)}] Copied {len(files)} notices in {time.monotonic()-started:.2f}s', flush=True)
    bundles = sorted(binaries.glob('*.bundle'))
    if not any(p.name == 'SwiftProtobuf_SwiftProtobuf.bundle' for p in bundles):
        raise ValueError('Missing SwiftProtobuf runtime resource bundle')
    for bundle in bundles:
        if bundle.is_symlink() or not bundle.is_dir():
            raise ValueError(f'Invalid resource bundle: {bundle.name}')
        contents = list(bundle.rglob('*'))
        if any(item.is_symlink() for item in contents):
            raise ValueError(f'Symlink in resource bundle: {bundle.name}')
        if not any(item.is_file() for item in contents):
            raise ValueError(f'Empty resource bundle: {bundle.name}')
        if any(not item.is_file() and not item.is_dir() for item in contents):
            raise ValueError(f'Unsupported entry in resource bundle: {bundle.name}')
        shutil.copytree(bundle, resources / bundle.name)
        print(time.strftime('[%H:%M:%S]'), f'Copied Swift resource bundle: {bundle.name}', flush=True)
    (notices / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'SUMMARY: {len(pins)} pinned dependency notice sets and {len(bundles)} resource bundles copied; not a legal or vulnerability clearance', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binaries', type=Path, required=True)
    parser.add_argument('--resources', type=Path, required=True)
    args = parser.parse_args()
    package_dependencies(Path(__file__).resolve().parents[1], args.binaries.resolve(), args.resources.resolve())

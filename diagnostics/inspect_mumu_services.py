#!/usr/bin/env python3
"""Read-only service observations from the explicitly named MuMu diagnostic VM."""
import argparse
import json
import os
from pathlib import Path

from run import ROOT, command, log
from run_mumu import TOOL


def diagnostic_serial(identity, current):
    index = identity.get('index')
    if type(index) is not int or index <= 0:
        raise ValueError('Never inspect user instance 0 with this collector')
    if identity.get('name') != 'Kestrel Diagnostic Baseline':
        raise ValueError('Unexpected saved diagnostic name')
    if current.get('name') != identity['name'] or current.get('bundle_path') != identity.get('bundle_path'):
        raise ValueError('Diagnostic identity mismatch')
    if not isinstance(identity.get('bundle_path'), str) or not identity['bundle_path']:
        raise ValueError('Missing saved bundle identity')
    if current.get('state') != 'running':
        raise ValueError('Diagnostic VM must already be running; collector never boots it')
    port = current.get('adb_port')
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError('Invalid diagnostic ADB port')
    return f'127.0.0.1:{port}'


def collect(shell):
    observations = {}
    queries = {
        'platform': ['getprop', 'ro.build.hv.platform'],
        'screen_enabled': ['getprop', 'sys.enable_screen'],
        'guest_mounts': ['cat', '/proc/mounts'],
        'prefetch_system_metadata': ['stat', '-c', '%s %Y', '/system/etc/mumu-configs/prefetch.config'],
        'prefetch_override_metadata': ['stat', '-c', '%s %Y', '/data/system/etc/mumu-configs/prefetch.config'],
        'optimizer_state': ['getprop', 'init.svc.nemu_sys_opt'],
        'nemuinit_state': ['getprop', 'init.svc.nemuinit'],
        'processes': ['ps', '-A'],
        'pagecache_policy': ['cat', '/proc/sys/vm/pagecache_limit_policy'],
        'optimizer_cpu_quota': ['cat', '/sys/fs/cgroup/nemu_sys_opt/cpu.max'],
        'optimizer_cpu_members': ['cat', '/sys/fs/cgroup/nemu_sys_opt/cgroup.procs'],
        'memory_pressure': ['cat', '/proc/pressure/memory'],
        'io_pressure': ['cat', '/proc/pressure/io'],
        'memory_info': ['cat', '/proc/meminfo'],
    }
    for number, (name, args) in enumerate(queries.items(), 1):
        log(f'[{number}/{len(queries)}] Read {name}')
        try:
            output = shell(args)
            observations[name] = {'status': 'observed', 'output': output}
            log(f'[{number}/{len(queries)}] {name}: observed')
        except RuntimeError as error:
            observations[name] = {'status': 'unavailable', 'error': str(error)}
            log(f'[{number}/{len(queries)}] {name}: unavailable, not evidence of absence')
    return observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    env = dict(os.environ)
    reference = ROOT / '.cocreate/research/mumu-runtime'
    identity = json.loads((reference / 'instance.json').read_text())
    if type(identity.get('index')) is not int or identity['index'] <= 0:
        raise ValueError('Invalid diagnostic index')

    def tool(*parts):
        value = json.loads(command([TOOL, *parts], env, timeout=10))
        if value.get('errcode') != 0:
            raise RuntimeError('MuMu identity query failed')
        return value['return']

    log('Preflight: verify diagnostic identity; no VM launch or settings changes')
    current = tool('info', str(identity['index']))
    serial = diagnostic_serial(identity, current)
    original = tool('config', '0')
    adb = Path.home() / 'Library/Android/sdk/platform-tools/adb'
    devices = command([adb, 'devices'], env, timeout=10).splitlines()
    if not any(row.split() == [serial, 'device'] for row in devices):
        raise RuntimeError('Diagnostic endpoint is not already connected; collector will not connect other devices')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'instance': identity, 'serial': serial, 'status': 'running',
              'limits': 'One-time read-only snapshot. No prefetch activation or performance conclusion.'}
    try:
        report['observations'] = collect(lambda parts: command([adb, '-s', serial, 'shell', *parts], env, timeout=5))
        if diagnostic_serial(identity, tool('info', str(identity['index']))) != serial:
            raise RuntimeError('Diagnostic endpoint changed during observation')
        if tool('config', '0') != original:
            raise RuntimeError('User instance configuration changed during observation')
        report['status'] = 'completed'
        report['original_user_config_unchanged'] = True
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        raise
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        log(f'SUMMARY: {report["status"]}; no guest settings written; pre-existing VM left in its original running state')


if __name__ == '__main__':
    main()

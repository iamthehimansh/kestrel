#!/usr/bin/env python3
"""Compare completed probe runs without treating callbacks as presented FPS."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time


def load_run(directory):
    summary = json.loads((directory / 'summary.json').read_text())
    if summary['status'] != 'completed' or len(summary['samples']) != 3:
        raise ValueError(f'Incomplete run: {directory}')
    requested = summary.get('requested_transport')
    if requested is not None and requested != summary['ro.boot.hardware.gltransport']:
        raise ValueError(f'Transport not activated: {directory}')
    samples = []
    for i, sample in enumerate(summary['samples'], 1):
        raw = json.loads((directory / sample['report']).read_text())
        if raw['status'] != 'completed':
            raise ValueError(f'Interrupted sample: {directory}/{sample["report"]}')
        text = (directory / f'gfxinfo-{i}.txt').read_text()
        def match(pattern):
            found = re.search(pattern, text)
            if found is None:
                raise ValueError(f'Missing metric {pattern} in {directory}')
            return found.group(1)
        samples.append({'sample': i, 'launch_seconds': sample['launch_seconds'],
                        'frame_p95_ms': int(match(r'95th percentile: (\d+)ms')),
                        'frame_p99_ms': int(match(r'99th percentile: (\d+)ms')),
                        'frames': int(match(r'Total frames rendered: (\d+)')),
                        'jank_current': match(r'Janky frames: ([^\n]+)'),
                        'jank_legacy': match(r'Janky frames \(legacy\): ([^\n]+)'),
                        'callback_p95_ms': raw['callback_intervals']['p95_ms'],
                        'touch_count': raw['touch_delivery_ages']['count'],
                        'renderer': raw['gles']['renderer']})
    return {'path': str(directory), 'summary_sha256': hashlib.sha256((directory / 'summary.json').read_bytes()).hexdigest(),
            'apk_sha256': summary['apk_sha256'], 'settings': summary['settings'],
            'transport': summary['ro.boot.hardware.gltransport'],
            'cold_boot': summary['cold_boot'], 'samples': samples,
            'worst_frame_p95_ms': max(s['frame_p95_ms'] for s in samples),
            'worst_frame_p99_ms': max(s['frame_p99_ms'] for s in samples),
            'worst_launch_seconds': max(s['launch_seconds'] for s in samples)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('runs', type=Path, nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(time.strftime('[%H:%M:%S]'), '[1/1] Compare completed samples, preserving all results', flush=True)
    runs = [load_run(path) for path in args.runs]
    first = runs[0]
    for run in runs[1:]:
        for key in ['apk_sha256', 'settings', 'cold_boot']:
            if run[key] != first[key]:
                raise ValueError(f'Comparison confounded by {key}: {run["path"]}')
        if {s['renderer'] for s in run['samples']} != {s['renderer'] for s in first['samples']}:
            raise ValueError('Renderer changed; not an isolated transport comparison')
    report = {'runs': runs, 'limits': [
        'A small Canvas workload, not game throughput or MuMu parity.',
        'Three within-boot repetitions are not independent boot replicates; reverse condition order before adopting changes.',
        'Android gfxinfo completion timing is not host-display presentation latency.',
        'Current and legacy jank definitions differ. Callback cadence alone is not FPS.',
        'Only two guest touch events per sample; not an input-latency benchmark.']}
    args.output.write_text(json.dumps(report, indent=2))
    for run in runs:
        print(json.dumps({k: run[k] for k in ['path', 'transport', 'worst_frame_p95_ms', 'worst_frame_p99_ms', 'worst_launch_seconds']}), flush=True)
    print(time.strftime('[%H:%M:%S]'), f'[1/1] PASS: {args.output}', flush=True)


if __name__ == '__main__':
    main()

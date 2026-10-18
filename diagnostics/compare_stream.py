#!/usr/bin/env python3
"""Summarize authenticated streaming diagnostics without claiming display latency."""
import argparse
import json
import math
from pathlib import Path
import time


def summarize(directory):
    report = json.loads((directory / 'report.json').read_text())
    if report.get('status') != 'completed' or not report.get('loopback_listener_verified'):
        raise ValueError('Incomplete or unverified listener: ' + str(directory))
    expected = {'missing_token': 'UNAUTHENTICATED', 'expired_token': 'INVALID_ARGUMENT',
                'wrong_audience': 'PERMISSION_DENIED'}
    if report.get('authentication_checks') != expected or not report.get('authenticated_screenshot'):
        raise ValueError('Authentication checks incomplete: ' + str(directory))
    delivery = report.get('delivery')
    samples = report.get('samples', [])
    if delivery not in ('inline', 'mmap') or len(samples) != 3:
        raise ValueError('Invalid delivery mode or sample count')
    rows = []
    for sample in samples:
        for key in ['seconds', 'received_frames_per_second', 'client_cpu_seconds',
                    'payload_MiB_per_second', 'median_estimated_frame_age_ms']:
            value = sample[key]
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError('Invalid measurement: ' + key)
        seconds = sample['seconds']
        frames = sample['frames']
        if seconds < 5 or seconds > 12 or type(frames) is not int or frames < 10:
            raise ValueError('Invalid stream duration/count')
        if not math.isclose(frames / seconds, sample['received_frames_per_second'], rel_tol=1e-6):
            raise ValueError('Frame rate does not match frame count and duration')
        if sample['last_seq'] < sample['first_seq'] + frames - 1:
            raise ValueError('Non-advancing frame sequence')
        expected_payload = frames * 1280 * 720 * 4 / seconds / 2**20 if delivery == 'inline' else 0
        if not math.isclose(expected_payload, sample['payload_MiB_per_second'], rel_tol=1e-6, abs_tol=1e-9):
            raise ValueError('Unexpected pixel payload for delivery mode')
        rows.append(dict(sample, client_cpu_fraction=sample['client_cpu_seconds']/seconds))
    # Output folder names differ in argv only through the access-policy file. Other
    # VM arguments must match; this is not permission to compare arbitrary configs.
    argv = list(report['argv'])
    policy = argv.index('-grpc-allowlist')
    argv[policy+1] = '<per-run-policy>'
    return {'path': str(directory), 'delivery': delivery, 'protocol_sha256': report['protocol_sha256'],
            'normalized_argv': argv, 'samples': rows,
            'lowest_received_fps': min(s['received_frames_per_second'] for s in rows),
            'highest_client_cpu_fraction': max(s['client_cpu_fraction'] for s in rows),
            'highest_sample_median_age_ms': max(s['median_estimated_frame_age_ms'] for s in rows),
            'consecutive_read_changes': sum(s['changed_between_consecutive_mmap_reads'] for s in rows)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('runs', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(time.strftime('[%H:%M:%S]'), '[1/1] Compare completed authenticated stream samples', flush=True)
    runs = [summarize(p) for p in args.runs]
    for run in runs[1:]:
        for key in ['protocol_sha256', 'normalized_argv']:
            if run[key] != runs[0][key]:
                raise ValueError('Comparison mismatch: ' + key)
    result = {'runs': runs, 'limits': [
        'Measured Python client CPU only, not emulator/server CPU or total energy.',
        'MMAP probe takes two copies/frame; inline uses protobuf-owned bytes. Neither is GPU zero-copy.',
        'Unchanged consecutive mapping reads cannot prove tear-free synchronization.',
        'Frame receive rate is not presentation FPS; timestamp age is not input-to-photon latency.',
        'Captured PNGs require visual inspection; protocol shape tests alone do not verify pixels.',
        'Short five-second samples on a 720p Canvas workload; not game or 1440p/120Hz performance.']}
    args.output.write_text(json.dumps(result, indent=2))
    for run in runs:
        print(json.dumps({k: run[k] for k in ['path', 'delivery', 'lowest_received_fps',
                                             'highest_client_cpu_fraction', 'highest_sample_median_age_ms']}), flush=True)
    print(time.strftime('[%H:%M:%S]'), '[1/1] PASS:', args.output, flush=True)


if __name__ == '__main__':
    main()

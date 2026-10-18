#!/usr/bin/env python3
"""Compare retained GLES runs; reject incomplete, mismatched or invalid rendering data."""
import argparse
import json
import math
from pathlib import Path
import time

WORKLOAD_FIELDS = ('workload', 'width', 'height', 'surface_width', 'surface_height',
                   'passes', 'shader_iterations', 'duration_seconds')


def check_pixels(data):
    def rgba(pixel):
        if not isinstance(pixel, list) or len(pixel) != 4:
            raise ValueError('Missing RGBA readback')
        if any(type(v) is not int or not 0 <= v <= 255 for v in pixel):
            raise ValueError('Invalid pixel channel')
    calibration = data.get('calibration_rgba')
    rgba(calibration)
    if any(abs(a - b) > 2 for a, b in zip(calibration, [64, 128, 191, 255])):
        raise ValueError('Calibration mismatch')
    colors = data.get('workload_readback_rgba')
    if not isinstance(colors, list) or len(colors) != 3:
        raise ValueError('Missing workload readback')
    for color, expected in zip(colors, [64, 128, 191]):
        rgba(color)
        if abs(color[1] - expected) > 3 or color[3] != 255:
            raise ValueError('Workload gradient/alpha mismatch')


def summarize(directory):
    summary = json.loads((directory / 'summary.json').read_text())
    if summary.get('status') != 'completed' or len(summary.get('samples', [])) != 3:
        raise ValueError(f'Run incomplete: {directory}')
    rows, signature = [], None
    for index in range(1, 4):
        data = json.loads((directory / f'sample-{index}.json').read_text())
        if data.get('status') != 'completed' or 'error' in data:
            raise ValueError(f'Sample failed: {directory}/{index}')
        check_pixels(data)
        current = {k: data[k] for k in WORKLOAD_FIELDS}
        if signature is not None and signature != current:
            raise ValueError('Workload changed between samples')
        signature = current
        row = {'sample': index, 'renderer': data['renderer'], 'sdk': data['sdk'],
               'compile_link_ms': data['compile_link_ms']}
        for metric, raw_name in [('completed_draw', 'completed_draw_ms'),
                                 ('frame_start_intervals', 'frame_start_intervals_ms')]:
            values = data[raw_name]
            if len(values) < 10 or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in values):
                raise ValueError('Invalid or insufficient timing samples')
            ordered = sorted(values)
            computed = {'count': len(values), 'median_ms': ordered[len(values)//2],
                        'p95_ms': ordered[math.ceil(len(values)*0.95)-1], 'max_ms': ordered[-1]}
            for key, value in computed.items():
                if not math.isclose(data[metric][key], value, rel_tol=1e-6, abs_tol=1e-6):
                    raise ValueError(f'Reported metric differs from raw timings: {metric}/{key}')
            row[metric] = computed
        rows.append(row)
    return {'path': str(directory), 'backend': summary['backend'], 'apk_sha256': summary['apk_sha256'],
            'headless': summary['headless'], 'settings': summary['settings'], 'workload': signature,
            'samples': rows,
            'worst_completed_draw_p95_ms': max(s['completed_draw']['p95_ms'] for s in rows),
            'worst_frame_start_p95_ms': max(s['frame_start_intervals']['p95_ms'] for s in rows)}


def selected_hardware(run):
    settings = run['settings']
    if run['backend'] == 'kestrel':
        return {'cpu': settings['cpuCount'], 'memory_mb': settings['memoryMB'],
                'width': settings['width'], 'height': settings['height'],
                'dpi': settings['dpi'], 'requested_fps': settings['fpsLimit']}
    if run['backend'] == 'mumu':
        width, height = map(int, settings['resolutionWidthHeight'].split('x'))
        if any(settings[key] for key in ['gpuFastMathEnable', 'dynamicFpsEnable', 'renderQualityEnable']):
            raise ValueError('Optional MuMu tuning enabled; not the normal-mode baseline')
        return {'cpu': settings['vmCpuCount'], 'memory_mb': settings['vmMemoryOfMB'],
                'width': width, 'height': height, 'dpi': settings['resolutionDPI'],
                'requested_fps': settings['maxFpsLimit']}
    raise ValueError('Unknown backend for hardware comparison')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('runs', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(time.strftime('[%H:%M:%S]'), '[1/1] Validate raw GLES samples and rendering readback', flush=True)
    runs = [summarize(p) for p in args.runs]
    for run in runs:
        run['selected_hardware'] = selected_hardware(run)
    for run in runs[1:]:
        for field in ['apk_sha256', 'workload', 'headless', 'selected_hardware']:
            if runs[0][field] != run[field]:
                raise ValueError(f'Comparison mismatch: {field}')
    report = {'runs': runs, 'limits': [
        'CPU-observed glFinish includes guest/host submission, queueing and GPU execution, not GPU-only time.',
        'Frame-start cadence is not host-display presentation FPS or input latency.',
        'Each directory is one boot with three within-boot repeats; Android versions/renderers differ. Run order and independent boot replication matter.',
        'Opaque repeated draws may be optimized by the implementation; this is not a fixed GPU instruction-count benchmark.',
        'Synthetic 720p shader workload cannot establish game compatibility or whole-product parity.']}
    args.output.write_text(json.dumps(report, indent=2))
    for run in runs:
        print(json.dumps({k: run[k] for k in ['backend', 'worst_completed_draw_p95_ms', 'worst_frame_start_p95_ms']}), flush=True)
    print(time.strftime('[%H:%M:%S]'), '[1/1] PASS:', args.output, flush=True)


if __name__ == '__main__':
    main()

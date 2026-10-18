import json
from pathlib import Path
import tempfile
import unittest
from compare import load_run


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.summary = {
            'status': 'completed', 'samples': [], 'requested_transport': 'pipe',
            'ro.boot.hardware.gltransport': 'pipe', 'cold_boot': True,
            'apk_sha256': 'fixture', 'settings': {'cpuCount': 2}}
        for n in range(1, 4):
            name = f'sample-{n}.json'
            self.summary['samples'].append({'report': name, 'launch_seconds': n / 10})
            (self.root / name).write_text(json.dumps({
                'status': 'completed', 'callback_intervals': {'p95_ms': 16.67},
                'touch_delivery_ages': {'count': 2}, 'gles': {'renderer': 'fixture'}}))
            (self.root / f'gfxinfo-{n}.txt').write_text(
                f'Total frames rendered: 100\nJanky frames: 1 (1%)\n'
                f'Janky frames (legacy): 2 (2%)\n95th percentile: {20+n}ms\n'
                f'99th percentile: {30+n}ms\n')
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    def save(self):
        (self.root / 'summary.json').write_text(json.dumps(self.summary))

    def test_keeps_every_sample_and_worst_case(self):
        result = load_run(self.root)
        self.assertEqual(len(result['samples']), 3)
        self.assertEqual(result['worst_frame_p95_ms'], 23)
        self.assertEqual(result['worst_frame_p99_ms'], 33)
        self.assertEqual(result['worst_launch_seconds'], 0.3)

    def test_rejects_failed_run(self):
        self.summary['status'] = 'failed'
        self.save()
        with self.assertRaises(ValueError):
            load_run(self.root)

    def test_rejects_missing_samples(self):
        self.summary['samples'].pop()
        self.save()
        with self.assertRaises(ValueError):
            load_run(self.root)

    def test_rejects_wrong_active_transport(self):
        self.summary['requested_transport'] = 'asg'
        self.save()
        with self.assertRaises(ValueError):
            load_run(self.root)

    def test_rejects_interrupted_sample(self):
        p = self.root / 'sample-2.json'
        data = json.loads(p.read_text())
        data['status'] = 'interrupted'
        p.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            load_run(self.root)

    def test_rejects_missing_metric(self):
        (self.root / 'gfxinfo-1.txt').write_text('No frame data')
        with self.assertRaises(ValueError):
            load_run(self.root)


if __name__ == '__main__':
    unittest.main(verbosity=2)

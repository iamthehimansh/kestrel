import copy
import json
from pathlib import Path
import tempfile
import unittest
from compare_gles import check_pixels, summarize


class GLESComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sample = {
            'status': 'completed', 'workload': 'gles-fixed-fbo-v1',
            'width': 1280, 'height': 720, 'surface_width': 1280, 'surface_height': 720,
            'passes': 4, 'shader_iterations': 24, 'duration_seconds': 20,
            'renderer': 'test renderer', 'sdk': 36, 'compile_link_ms': 1,
            'calibration_rgba': [64, 128, 191, 255],
            'workload_readback_rgba': [[10, 64, 20, 255], [10, 128, 20, 255], [10, 191, 20, 255]],
            'completed_draw_ms': [1.0] * 19 + [2.0],
            'completed_draw': {'count': 20, 'median_ms': 1.0, 'p95_ms': 1.0, 'max_ms': 2.0},
            'frame_start_intervals_ms': [16.0] * 20,
            'frame_start_intervals': {'count': 20, 'median_ms': 16.0, 'p95_ms': 16.0, 'max_ms': 16.0}}
        (self.root / 'summary.json').write_text(json.dumps({
            'status': 'completed', 'samples': [{}, {}, {}], 'backend': 'test',
            'headless': False, 'settings': {}, 'apk_sha256': 'test'}))
        for i in range(1, 4):
            self.write(i, self.sample)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, i, sample):
        (self.root / f'sample-{i}.json').write_text(json.dumps(sample))

    def test_recomputes_from_raw_samples(self):
        result = summarize(self.root)
        self.assertEqual(result['worst_completed_draw_p95_ms'], 1.0)
        self.assertEqual(len(result['samples']), 3)

    def test_rejects_falsely_reported_percentile(self):
        bad = copy.deepcopy(self.sample)
        bad['completed_draw']['p95_ms'] = 0.5
        self.write(1, bad)
        with self.assertRaisesRegex(ValueError, 'differs from raw'):
            summarize(self.root)

    def test_rejects_nonfinite_and_negative_raw_times(self):
        for value in [float('nan'), float('inf'), -1.0]:
            bad = copy.deepcopy(self.sample)
            bad['completed_draw_ms'][0] = value
            self.write(1, bad)
            with self.assertRaisesRegex(ValueError, 'Invalid or insufficient'):
                summarize(self.root)

    def test_rejects_changed_workload(self):
        bad = copy.deepcopy(self.sample)
        bad['passes'] = 1
        self.write(2, bad)
        with self.assertRaisesRegex(ValueError, 'Workload changed'):
            summarize(self.root)

    def test_rejects_wrong_calibration(self):
        bad = copy.deepcopy(self.sample)
        bad['calibration_rgba'][0] = 0
        with self.assertRaisesRegex(ValueError, 'Calibration mismatch'):
            check_pixels(bad)

    def test_rejects_incorrect_gradient_or_alpha(self):
        for channel, value in [(1, 0), (3, 0)]:
            bad = copy.deepcopy(self.sample)
            bad['workload_readback_rgba'][1][channel] = value
            with self.assertRaisesRegex(ValueError, 'gradient/alpha mismatch'):
                check_pixels(bad)

    def test_rejects_invalid_pixel_shape(self):
        for value in [None, [1, 2], [1, 2, 3, 256], [True, 128, 191, 255]]:
            bad = copy.deepcopy(self.sample)
            bad['calibration_rgba'] = value
            with self.assertRaises(ValueError):
                check_pixels(bad)


if __name__ == '__main__':
    unittest.main(verbosity=2)

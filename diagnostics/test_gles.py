import copy
import unittest
from run_gles import validate_report


class GLESReportTests(unittest.TestCase):
    def setUp(self):
        self.report = {
            'status': 'completed', 'workload': 'gles-fixed-fbo-v1',
            'width': 1280, 'height': 720, 'surface_width': 1280, 'surface_height': 720,
            'passes': 4, 'shader_iterations': 24,
            'completed_draw': {'count': 100}, 'frame_start_intervals': {'count': 100},
            'calibration_rgba': [64, 128, 191, 255],
            'workload_readback_rgba': [[50, 64, 120, 255], [50, 128, 120, 255], [50, 191, 120, 255]]}

    def test_accepts_completed_fixed_workload(self):
        validate_report(self.report)

    def test_rejects_interrupted_or_failed_run(self):
        for status in ['interrupted', 'failed']:
            report = copy.deepcopy(self.report)
            report['status'] = status
            with self.assertRaises(ValueError):
                validate_report(report)

    def test_rejects_dimension_and_workload_mismatch(self):
        for key, value in [('surface_height', 684), ('width', 1920), ('passes', 1), ('shader_iterations', 1)]:
            report = copy.deepcopy(self.report)
            report[key] = value
            with self.assertRaises(ValueError):
                validate_report(report)

    def test_rejects_missing_readback_and_insufficient_samples(self):
        for key in ['calibration_rgba', 'workload_readback_rgba']:
            report = copy.deepcopy(self.report)
            report.pop(key)
            with self.assertRaises(ValueError):
                validate_report(report)
        for key in ['completed_draw', 'frame_start_intervals']:
            report = copy.deepcopy(self.report)
            report[key]['count'] = 0
            with self.assertRaises(ValueError):
                validate_report(report)


if __name__ == '__main__':
    unittest.main(verbosity=2)

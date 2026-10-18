import copy
import json
from pathlib import Path
import tempfile
import unittest
from compare_stream import summarize


class StreamComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        sample = {'frames': 300, 'seconds': 5.0, 'received_frames_per_second': 60.0,
                  'client_cpu_seconds': 0.25, 'payload_MiB_per_second': 0.0,
                  'first_seq': 1, 'last_seq': 300, 'median_estimated_frame_age_ms': 2.0,
                  'changed_between_consecutive_mmap_reads': 0}
        self.report = {'status': 'completed', 'loopback_listener_verified': True,
                       'authenticated_screenshot': True, 'delivery': 'mmap',
                       'protocol_sha256': 'fixture',
                       'authentication_checks': {'missing_token': 'UNAUTHENTICATED',
                           'expired_token': 'INVALID_ARGUMENT', 'wrong_audience': 'PERMISSION_DENIED'},
                       'samples': [dict(sample, sample=i) for i in range(1, 4)],
                       'argv': ['emulator', '-grpc-use-jwt', '-grpc-allowlist', '/test/policy.json']}
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        (self.root / 'report.json').write_text(json.dumps(self.report))

    def test_reports_cpu_fraction_without_claiming_zero_copy(self):
        result = summarize(self.root)
        self.assertEqual(result['highest_client_cpu_fraction'], 0.05)
        self.assertEqual(result['lowest_received_fps'], 60)
        self.assertEqual(result['normalized_argv'][-1], '<per-run-policy>')

    def test_rejects_unverified_authentication(self):
        self.report['authentication_checks'].pop('expired_token')
        self.save()
        with self.assertRaises(ValueError):
            summarize(self.root)

    def test_rejects_mmap_fallback_to_inline(self):
        self.report['samples'][0]['payload_MiB_per_second'] = 211.0
        self.save()
        with self.assertRaisesRegex(ValueError, 'pixel payload'):
            summarize(self.root)

    def test_checks_inline_byte_count(self):
        self.report['delivery'] = 'inline'
        for sample in self.report['samples']:
            sample['payload_MiB_per_second'] = 300 * 1280 * 720 * 4 / 5 / 2**20
        self.save()
        self.assertEqual(summarize(self.root)['delivery'], 'inline')

    def test_rejects_invalid_samples(self):
        original = copy.deepcopy(self.report)
        for key, value in [('seconds', 0), ('received_frames_per_second', 120),
                           ('client_cpu_seconds', float('nan')), ('last_seq', 2)]:
            self.report = copy.deepcopy(original)
            self.report['samples'][0][key] = value
            self.save()
            with self.assertRaises(ValueError, msg=key):
                summarize(self.root)


if __name__ == '__main__':
    unittest.main(verbosity=2)

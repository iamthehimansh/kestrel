import os
from pathlib import Path
import tempfile
import unittest
from shared_frame import SharedFrame


class SharedFrameTests(unittest.TestCase):
    def test_owned_mapping_capture_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            frame = SharedFrame(directory, 2, 2)
            path = frame.path
            try:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertTrue(frame.uri.startswith('file:///'))
                pixels = bytes(range(16))
                with path.open('r+b') as writer:
                    writer.write(pixels)
                    writer.flush()
                captured, changed = frame.capture()
                self.assertEqual(captured, pixels)
                self.assertFalse(changed)
            finally:
                frame.close()
            self.assertFalse(path.exists())
            frame.close()
            with self.assertRaises(RuntimeError):
                frame.capture()

    def test_invalid_size_creates_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            for width, height in [(0, 1), (1, -1), (True, 2), (4096, 4096), (5000, 1)]:
                with self.assertRaises(ValueError):
                    SharedFrame(directory, width, height)
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)

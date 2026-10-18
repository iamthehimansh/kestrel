"""Owned, bounded raw-frame mapping for the emulator's file:// MMAP transport."""
import mmap
import os
from pathlib import Path
import tempfile


class SharedFrame:
    def __init__(self, directory, width, height):
        if type(width) is not int or type(height) is not int or not 1 <= width <= 4096 or not 1 <= height <= 4096:
            raise ValueError('Invalid diagnostic frame size')
        self.size = width * height * 4
        if self.size > 32 * 1024 * 1024:
            raise ValueError('Frame exceeds diagnostic memory budget')
        self.mapping = None
        fd, name = tempfile.mkstemp(prefix='kestrel-frame-', dir=directory)
        self.path = Path(name)
        try:
            os.fchmod(fd, 0o600)
            os.ftruncate(fd, self.size)
            self.mapping = mmap.mmap(fd, self.size, access=mmap.ACCESS_WRITE)
        except Exception:
            self.path.unlink(missing_ok=True)
            raise
        finally:
            os.close(fd)

    @property
    def uri(self):
        return self.path.resolve().as_uri()

    def capture(self):
        if self.mapping is None:
            raise RuntimeError('Mapping closed')
        first = self.mapping[:]
        second = self.mapping[:]
        # Two equal reads are only a heuristic. The producer has no seqlock/fence contract;
        # even equal copies do not prove the frame is tear-free or matches the notification.
        return second, first != second

    def close(self):
        try:
            if self.mapping is not None:
                self.mapping.close()
                self.mapping = None
        finally:
            self.path.unlink(missing_ok=True)

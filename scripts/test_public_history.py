import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).with_name('check-public-history.py').resolve()


class PublicHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_AUTHOR_NAME='Himansh Raj',
                        GIT_AUTHOR_EMAIL='iamthehimansh@gmail.com',
                        GIT_COMMITTER_NAME='Himansh Raj',
                        GIT_COMMITTER_EMAIL='iamthehimansh@gmail.com')
        self.git('init')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], env=self.env,
                              capture_output=True, text=True, check=True)

    def commit(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        self.git('add', '--', path)
        self.git('commit', '-m', 'fixture')

    def scan(self):
        return subprocess.run([sys.executable, str(CHECK), '--repo', str(self.root)],
                              capture_output=True, text=True, timeout=20)

    def test_clean_history_passes(self):
        self.commit('README.md', '# Fixture\n')
        self.assertEqual(self.scan().returncode, 0)

    def test_old_private_content_fails_even_after_removal(self):
        self.commit('notes.txt', '/Users/' + 'iamthehimansh/private-fixture\n')
        self.git('rm', 'notes.txt')
        self.git('commit', '-m', 'remove')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn('local home path', result.stdout)

    def test_same_blob_at_forbidden_path_is_detected(self):
        self.commit('a.txt', 'identical innocuous bytes\n')
        self.commit('research/stealth/results/capture.txt', 'identical innocuous bytes\n')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn('forbidden path research/stealth/results/capture.txt', result.stdout)

    def test_wrong_identity_fails(self):
        self.env['GIT_AUTHOR_NAME'] = 'Fixture Contributor'
        self.commit('README.md', '# Fixture\n')
        self.assertEqual(self.scan().returncode, 1)

    def test_large_blob_fails_instead_of_being_silently_skipped(self):
        self.commit('large.txt', 'x' * 5_000_001)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn('unscanned large blob', result.stdout)


if __name__ == '__main__':
    unittest.main()

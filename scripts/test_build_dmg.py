import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DiskImageBuildTests(unittest.TestCase):
    def test_cold_touch_build_does_not_require_executable_bit(self):
        source = Path(__file__).with_name('build-app.sh').read_text()
        start = source.index('build_touch() {')
        end = source.index('\n}\n', start) + 3
        function = source[start:end]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'touchd').mkdir()
            helper = root / 'touchd/build.sh'
            helper.write_text('#!/bin/sh\nmkdir -p .build/touchd\nprintf helper > .build/touchd/touchd\n')
            helper.chmod(0o600)
            result = subprocess.run(['bash', '-eu', '-c', function + '\nbuild_touch'], cwd=root,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / '.build/touchd/touchd').read_text(), 'helper')

    def test_nested_app_script_does_not_require_executable_bit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            scripts.mkdir()
            shutil.copy2(Path(__file__).with_name('build-dmg.sh'), scripts / 'build-dmg.sh')
            (scripts / 'lib').mkdir()
            (scripts / 'lib/progress.sh').write_text('run_step() { shift; "$@"; }\n')
            app_script = scripts / 'build-app.sh'
            app_script.write_text('#!/bin/bash\nmkdir -p build/Kestrel.app\nprintf built > build/app-built\n')
            app_script.chmod(0o600)
            tools = root / 'tools'
            tools.mkdir()
            for name, body in {
                'codesign': '#!/bin/bash\nexit 0\n',
                'hdiutil': '#!/bin/bash\nif [ "$1" = create ]; then printf image > "${@: -1}"; else test -f "$2"; fi\n',
            }.items():
                tool = tools / name
                tool.write_text(body)
                tool.chmod(0o700)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], KESTREL_VERSION='0.1.0')
            env.pop('SKIP_APP_BUILD', None)
            result = subprocess.run(['bash', str(scripts / 'build-dmg.sh')], cwd=root,
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / 'build/app-built').read_text(), 'built')
            self.assertEqual((root / 'build/Kestrel-0.1.0.dmg').read_text(), 'image')


if __name__ == '__main__':
    unittest.main()

"""Exercise release-script guards; signing/architecture are stubbed, not certified."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'Release scripts require macOS tools')
class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        for name in ['build-app.sh', 'package-release.sh']:
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.app = self.root / 'Remeet.app'
        self.binary = self.app / 'Contents/MacOS/Remeet'
        self.binary.parent.mkdir(parents=True)
        tools = self.root / 'tools'
        tools.mkdir()
        for name, script in [('lipo', 'echo arm64'), ('codesign', 'exit 0')]:
            tool = tools / name
            tool.write_text('#!/bin/sh\n' + script + '\n')
            tool.chmod(0o755)
        self.env = dict(os.environ, REMEET_APP_OUTPUT=str(self.app),
                        PATH=str(tools) + os.pathsep + os.environ['PATH'])

    def run_script(self, name):
        return subprocess.run(['bash', str(self.root / 'scripts' / name)],
                              env=self.env, capture_output=True, text=True)

    def test_existing_build_is_refused_and_preserved(self):
        self.binary.write_bytes(b'previous binary')
        leftover = self.app / 'obsolete-resource.txt'
        leftover.write_text('previous resource')
        result = self.run_script('build-app.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Output already exists', result.stderr)
        self.assertEqual(self.binary.read_bytes(), b'previous binary')
        self.assertEqual(leftover.read_text(), 'previous resource')

    def test_package_allows_clean_bytes_but_rejects_paths_scan_errors_and_overwrite(self):
        private_path = ('/Users/' + 'example' + '/build/source.swift').encode()
        for label, data in [('clean', b'ordinary bytes'),
                            ('private', b'header\0' + private_path + b'\0trailer'),
                            ('unreadable', None)]:
            with self.subTest(label=label):
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleShortVersionString': label}))
                if data is None:
                    self.binary.unlink()
                else:
                    self.binary.write_bytes(data)
                archive = self.root / f'build/releases/Remeet-{label}-arm64.zip'
                result = self.run_script('package-release.sh')
                if label == 'clean':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    original = archive.read_bytes()
                    self.assertNotEqual(self.run_script('package-release.sh').returncode, 0)
                    self.assertEqual(archive.read_bytes(), original)
                    self.assertTrue(archive.with_name(archive.name + '.sha256').exists())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Refusing package:', result.stderr)
                    self.assertFalse(archive.exists())
                    self.assertNotIn(private_path.decode(), result.stderr)


if __name__ == '__main__':
    unittest.main()

"""Opt-in native integration: REMEET_TEST_BINARY=.build/debug/Remeet."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid

BINARY = os.environ.get('REMEET_TEST_BINARY')
OLD_BINARY = os.environ.get('REMEET_TEST_OLD_BINARY')
ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(BINARY, 'Set REMEET_TEST_BINARY to a freshly built Debug executable on macOS')
class ReloadBridgeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / 'RemeetImportQA.app'
        self.binary = self.bundle / 'Contents/MacOS/Remeet'
        self.binary.parent.mkdir(parents=True)
        resources = self.bundle / 'Contents/Resources'
        resources.mkdir()
        shutil.copy2(ROOT / 'quotes.example.json', resources / 'quotes.example.json')
        with (ROOT / 'Resources/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        info['CFBundleIdentifier'] = 'local.Remeet.ImportQA.' + uuid.uuid4().hex
        (self.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        self.target = self.root / 'data/quotes.json'
        self.target.parent.mkdir()
        self.suite = info['CFBundleIdentifier'] + '.preferences'
        self.addCleanup(subprocess.run, ['defaults', 'delete', self.suite], capture_output=True)
        for key in ['showIndicator', 'autoPresent', 'hoverPresent']:
            subprocess.run(['defaults', 'write', self.suite, key, '-bool', 'false'], check=True)
        self.env = dict(os.environ, REMEET_DATA_DIR=str(self.target.parent), REMEET_DEFAULTS_SUITE=self.suite)
        self.process = None
        self.addCleanup(self.stop_app)

    def stop_app(self):
        if self.process is not None:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process = None

    def start_app(self, binary=BINARY, expected_status='reloaded'):
        from test_content_skill import content
        self.assertIsNone(self.process)
        shutil.copy2(Path(binary).resolve(), self.binary)
        self.process = subprocess.Popen([str(self.binary)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = None
        for _ in range(3):
            result = content.notify_app(self.bundle, self.target)
            if result['status'] == expected_status: break
            self.assertIsNone(self.process.poll(), 'Debug test app exited')
        self.assertEqual(result['status'], expected_status, result)
        return result

    def data_snapshot(self):
        return {str(path.relative_to(self.target.parent)): path.read_bytes()
                for path in self.target.parent.rglob('*') if path.is_file()}

    def test_isolated_app_acknowledges_import_and_keeps_last_valid_pool(self):
        from test_content_skill import content
        self.target.write_text('[{"text":"original"}]')
        self.assertEqual(self.start_app()['count'], 1)
        incoming = self.root / 'candidate.json'
        incoming.write_text('[{"text":"imported 中文"}]')
        receipt = content.apply_plan(content.create_plan(incoming, self.target, 'merge'))
        self.assertEqual(receipt['status'], 'written')
        result = content.notify_app(self.bundle, self.target)
        self.assertEqual(result['status'], 'reloaded', result)
        self.assertEqual(result['count'], 2)
        self.target.write_text('invalid json')
        result = content.notify_app(self.bundle, self.target)
        self.assertEqual(result['status'], 'reload_failed', result)
        self.assertEqual(result['count'], 2)
        self.target.write_text('[{"text":"recovered"}]')
        self.assertEqual(content.notify_app(self.bundle, self.target)['count'], 1)
        self.assertEqual(content.notify_app(self.bundle, self.root / 'wrong.json')['status'], 'not_acknowledged')

    def test_first_launch_and_restarts_preserve_existing_empty_and_invalid_files(self):
        samples = (ROOT / 'quotes.example.json').read_bytes()
        self.assertEqual(self.start_app()['count'], len(json.loads(samples)))
        self.assertEqual(self.target.read_bytes(), samples)
        self.stop_app()
        cases = [(b'[]', 'reloaded', 0), (b'broken json', 'reload_failed', 0),
                 ('[ {"text":"旧格式无标签","source":"保留来源"} ]'.encode(), 'reloaded', 1)]
        for data, status, count in cases:
            with self.subTest(status=status, data=data):
                self.target.write_bytes(data)
                for _ in range(2):
                    self.assertEqual(self.start_app(expected_status=status)['count'], count)
                    self.assertEqual(self.data_snapshot(), {'quotes.json': data})
                    self.stop_app()

    @unittest.skipUnless(OLD_BINARY, 'Set REMEET_TEST_OLD_BINARY to a prior Debug executable for upgrade coverage')
    def test_previous_binary_replacement_preserves_notes_preferences_and_recovery_files(self):
        from test_content_skill import content
        original = '[ {"text":"旧笔记","source":"原来源"}, {"text":"带标签的笔记","tags":["阅读"]} ]'.encode()
        self.target.write_bytes(original)
        for directory in ['editor-backups', 'import-backups', 'draft-exports']:
            path = self.target.parent / directory / 'quotes-fixture.json'
            path.parent.mkdir()
            path.write_bytes(original)
        for key, kind, value in [('isPaused', '-bool', 'true'), ('frequencyMinutes', '-int', '0'),
                                 ('customIntervalMinutes', '-int', '37'), ('readingSeconds', '-int', '19')]:
            subprocess.run(['defaults', 'write', self.suite, key, kind, value], check=True)
        preferences = plistlib.loads(subprocess.check_output(['defaults', 'export', self.suite, '-']))
        before = self.data_snapshot()
        self.assertEqual(self.start_app(binary=OLD_BINARY)['count'], 2)
        self.stop_app()
        self.assertEqual(self.start_app()['count'], 2)
        self.assertEqual(self.data_snapshot(), before)
        self.assertEqual(plistlib.loads(subprocess.check_output(['defaults', 'export', self.suite, '-'])), preferences)
        incoming = self.root / 'incoming.json'
        incoming.write_text('[{"text":"升级后新增","tags":["工作"]}]')
        content.apply_plan(content.create_plan(incoming, self.target, 'merge'))
        self.assertEqual(content.notify_app(self.bundle, self.target)['count'], 3)
        saved = self.data_snapshot()
        self.stop_app()
        self.assertEqual(self.start_app()['count'], 3)
        self.assertEqual(self.data_snapshot(), saved)

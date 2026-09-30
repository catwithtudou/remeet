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
ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(BINARY, 'Set REMEET_TEST_BINARY to a freshly built Debug executable on macOS')
class ReloadBridgeTests(unittest.TestCase):
    def test_isolated_app_acknowledges_import_and_keeps_last_valid_pool(self):
        from test_content_skill import content
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'RemeetImportQA.app'
            binary = bundle / 'Contents/MacOS/Remeet'
            binary.parent.mkdir(parents=True)
            shutil.copy2(Path(BINARY).resolve(), binary)
            with (ROOT / 'Resources/Info.plist').open('rb') as stream:
                info = plistlib.load(stream)
            info['CFBundleIdentifier'] = 'local.Remeet.ImportQA.' + uuid.uuid4().hex
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            target = root / 'data/quotes.json'
            target.parent.mkdir()
            target.write_text('[{"text":"original"}]')
            suite = info['CFBundleIdentifier']
            for key in ['showIndicator', 'autoPresent', 'hoverPresent']:
                subprocess.run(['defaults', 'write', suite, key, '-bool', 'false'], check=True)
            env = dict(os.environ, REMEET_DATA_DIR=str(target.parent), REMEET_DEFAULTS_SUITE=suite)
            process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                result = None
                for _ in range(3):
                    result = content.notify_app(bundle, target)
                    if result['status'] == 'reloaded': break
                    self.assertIsNone(process.poll(), 'Debug test app exited')
                self.assertEqual(result['status'], 'reloaded', result)
                self.assertEqual(result['count'], 1)
                incoming = root / 'candidate.json'
                incoming.write_text('[{"text":"imported 中文"}]')
                receipt = content.apply_plan(content.create_plan(incoming, target, 'merge'))
                self.assertEqual(receipt['status'], 'written')
                result = content.notify_app(bundle, target)
                self.assertEqual(result['status'], 'reloaded', result)
                self.assertEqual(result['count'], 2)
                target.write_text('invalid json')
                result = content.notify_app(bundle, target)
                self.assertEqual(result['status'], 'reload_failed', result)
                self.assertEqual(result['count'], 2)
                target.write_text('[{"text":"recovered"}]')
                self.assertEqual(content.notify_app(bundle, target)['count'], 1)
                self.assertEqual(content.notify_app(bundle, root / 'wrong.json')['status'], 'not_acknowledged')
            finally:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                subprocess.run(['defaults', 'delete', suite], capture_output=True)

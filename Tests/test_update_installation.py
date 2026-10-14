"""Run the real installer helper and Launch Services against disposable Debug apps.

Fixtures are local Debug apps; an opt-in case retains quarantine during real launches.
User approval of an internet-downloaded release remains a manual acceptance gate;
the live Swift check retains quarantine but never launches that release.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('REMEET_TEST_BINARY')


@unittest.skipUnless(sys.platform == 'darwin' and BINARY, 'Set REMEET_TEST_BINARY to an isolated Debug executable')
class UpdateInstallationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='Remeet update integration-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        # An absolute-path suite keeps cfprefsd's leftover empty plist out of ~/Library/Preferences.
        self.suite = str(self.root / 'preferences')
        self.env = dict(os.environ, REMEET_DATA_DIR=str(self.root / 'data'),
                        REMEET_DEFAULTS_SUITE=self.suite, REMEET_UPDATE_TEST_NO_ALERT='1')
        self.processes = []
        self.addCleanup(self.stop_processes)
        self.data = self.root / 'data'
        self.data.mkdir()
        original = '[ {"text":"隔离笔记","source":"来源","tags":["保留"]} ]'.encode()
        (self.data / 'quotes.json').write_bytes(original)
        for directory in ['editor-backups', 'import-backups', 'draft-exports']:
            (self.data / directory).mkdir()
            (self.data / directory / 'retained.json').write_bytes(original)
        subprocess.run(['defaults', 'write', self.suite, 'isPaused', '-bool', 'true'], check=True)
        subprocess.run(['defaults', 'write', self.suite, 'customIntervalMinutes', '-int', '37'], check=True)
        self.before_preferences = self.preferences()
        self.before_data = self.snapshot()
        self.target = self.make_app(self.root / 'Remeet.app', '0.2.16', Path(BINARY).resolve())
        self.target_fingerprint = self.fingerprint(self.target)

    def preferences(self):
        return plistlib.loads(subprocess.check_output(['defaults', 'export', self.suite, '-']))

    def snapshot(self):
        return {str(p.relative_to(self.data)): p.read_bytes() for p in self.data.rglob('*') if p.is_file()}

    def make_app(self, app, version, binary):
        (app / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(binary, app / 'Contents/MacOS/Remeet')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.NotchRecall', 'CFBundleExecutable': 'Remeet',
            'CFBundleName': 'Remeet', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version,
            'CFBundleVersion': '19', 'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
            'NSPrincipalClass': 'NSApplication', 'NotchRecallContentReloadVersion': 1,
            'RemeetBuildKind': 'development'}))
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        return app

    @staticmethod
    def fingerprint(app):
        files = ['Contents/Info.plist', 'Contents/MacOS/Remeet', 'Contents/_CodeSignature/CodeResources']
        return ':'.join(hashlib.sha256((app / file).read_bytes()).hexdigest() for file in files)

    def spawn(self, args, stderr=subprocess.DEVNULL):
        process = subprocess.Popen(args, env=self.env, stdout=subprocess.DEVNULL, stderr=stderr)
        self.processes.append(process)
        return process

    def wait_for(self, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.1)
        self.fail('Timed out waiting for isolated update state')

    def receipt(self):
        path = self.root / 'installation.json'
        return json.loads(path.read_text()) if path.exists() else {}

    def start_installation(self, candidate_binary, before_quit=None):
        from test_content_skill import content
        old = self.spawn([str(self.target / 'Contents/MacOS/Remeet')])
        self.wait_for(lambda: content.notify_app(self.target, self.data / 'quotes.json').get('status') == 'reloaded')
        workspace = self.root / ('.remeet-update-' + str(uuid.uuid4()).upper())
        workspace.mkdir()
        candidate = self.make_app(workspace / 'candidate.app', '0.2.17', candidate_binary)
        candidate_fingerprint = self.fingerprint(candidate)
        shutil.copy2(self.target / 'Contents/MacOS/Remeet', workspace / 'installer')
        directory_url = lambda path: path.as_uri() + '/'
        plan = {'workspace': directory_url(workspace), 'target': directory_url(self.target),
                'receipt': (self.root / 'installation.json').as_uri(), 'parentPID': old.pid,
                'oldFingerprint': self.target_fingerprint, 'newFingerprint': candidate_fingerprint,
                'version': '0.2.17', 'architecture': subprocess.check_output(['uname', '-m'], text=True).strip()}
        plan_file = workspace / 'plan.json'
        plan_file.write_text(json.dumps(plan))
        with (self.root / 'helper.log').open('wb') as log:
            helper = self.spawn([str(workspace / 'installer'), '--install-update', str(plan_file)], stderr=log)
        self.wait_for(lambda: self.receipt().get('status') == 'waiting' or helper.poll() is not None)
        self.assertEqual(self.receipt().get('status'), 'waiting', (self.receipt(), (self.root / 'helper.log').read_text()))
        self.assertEqual(self.fingerprint(self.target), self.target_fingerprint)
        self.assertFalse((workspace / 'previous.app').exists())
        if before_quit:
            before_quit(workspace)
        old.terminate()  # Only a disposable, unedited fixture; draft gating is covered in Swift.
        old.wait(timeout=5)
        return workspace, helper, candidate_fingerprint

    def test_helper_waits_then_atomically_replaces_restarts_and_preserves_data(self):
        from test_content_skill import content
        workspace, helper, new_fingerprint = self.start_installation(Path(BINARY).resolve())
        helper.wait(timeout=30)
        self.assertEqual(self.receipt().get('status'), 'complete', self.receipt())
        self.assertEqual(self.fingerprint(self.target), new_fingerprint)
        self.assertEqual(self.fingerprint(workspace / 'previous.app'), self.target_fingerprint)
        self.assertEqual(content.notify_app(self.target, self.data / 'quotes.json')['status'], 'reloaded')
        self.assertEqual(self.snapshot(), self.before_data)
        self.assertEqual(self.preferences(), self.before_preferences)

    def test_new_process_exit_rolls_back_and_restarts_original(self):
        from test_content_skill import content
        crash = self.root / 'crash'
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(crash)],
                       input='int main(void) { return 42; }', text=True, check=True, capture_output=True)
        workspace, helper, _ = self.start_installation(crash)
        helper.wait(timeout=30)
        self.assertEqual(self.receipt().get('status'), 'rolledBack', self.receipt())
        self.assertEqual(self.fingerprint(self.target), self.target_fingerprint)
        self.assertEqual(self.fingerprint(workspace / 'previous.app'), self.target_fingerprint)
        self.assertEqual(content.notify_app(self.target, self.data / 'quotes.json')['status'], 'reloaded')
        self.assertEqual(self.snapshot(), self.before_data)
        self.assertEqual(self.preferences(), self.before_preferences)

    def test_candidate_changed_after_helper_ready_restarts_original_without_replacement(self):
        from test_content_skill import content

        def damage_candidate(workspace):
            (workspace / 'candidate.app/Contents/Info.plist').write_bytes(b'changed after readiness')

        workspace, helper, _ = self.start_installation(Path(BINARY).resolve(), before_quit=damage_candidate)
        helper.wait(timeout=30)
        self.assertEqual(self.receipt().get('status'), 'failed', self.receipt())
        self.assertEqual(self.fingerprint(self.target), self.target_fingerprint)
        self.assertFalse((workspace / 'previous.app').exists())
        self.assertEqual(content.notify_app(self.target, self.data / 'quotes.json')['status'], 'reloaded')
        self.assertEqual(self.snapshot(), self.before_data)
        self.assertEqual(self.preferences(), self.before_preferences)

    @unittest.skipUnless(os.environ.get('REMEET_TEST_QUARANTINED_UPDATES') == '1',
                         'Opt in on a desktop Mac to exercise real quarantined app launches')
    def test_quarantined_candidate_does_not_leave_a_second_app_after_recovery(self):
        from test_content_skill import content

        def quarantine(workspace):
            subprocess.run(['xattr', '-w', 'com.apple.quarantine',
                            '0081;00000000;;' + str(uuid.uuid4()).upper(),
                            str(workspace / 'candidate.app')], check=True)

        workspace, helper, new_fingerprint = self.start_installation(Path(BINARY).resolve(), before_quit=quarantine)
        helper.wait(timeout=90)  # System policy and a refused normal quit can delay the launch result.
        status = self.receipt().get('status')
        self.assertIn(status, ['rolledBack', 'complete', 'manualRecovery'], self.receipt())
        self.assertEqual(self.fingerprint(self.target), self.target_fingerprint if status == 'rolledBack' else new_fingerprint)
        self.assertEqual(self.fingerprint(workspace / 'previous.app'), self.target_fingerprint)
        retained = workspace / 'candidate.app' if status == 'rolledBack' else self.target
        self.assertTrue(subprocess.check_output(['xattr', '-p', 'com.apple.quarantine', str(retained)]).strip())
        if status == 'manualRecovery':
            self.assertIn('新 App 仍在运行', self.receipt().get('message', ''))
        else:
            self.assertEqual(content.notify_app(self.target, self.data / 'quotes.json')['status'], 'reloaded')
        process_count = len(self.owned_app_pids())
        self.assertLessEqual(process_count, 1, 'A failed launch left a second fixture app running')
        if status != 'manualRecovery':
            self.assertEqual(process_count, 1)
        self.assertEqual(self.snapshot(), self.before_data)
        self.assertEqual(self.preferences(), self.before_preferences)

    def owned_app_pids(self):
        # Match only this fixture's unique environment, including translocated instances.
        listing = subprocess.check_output(['ps', 'eww', '-axo', 'pid=,stat=,command='], text=True)
        result = []
        for line in listing.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and not fields[1].startswith('Z'):
                pid, _, command = fields
                if ('/Contents/MacOS/Remeet' in command and '--reload-content' not in command
                        and 'REMEET_DATA_DIR=' + str(self.data) in command):
                    result.append(int(pid))
        return result

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        # Stop only disposable children after assertions, including App Translocation.
        for pid in self.owned_app_pids():
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
        subprocess.run(['defaults', 'delete', self.suite], capture_output=True)


if __name__ == '__main__':
    unittest.main()

import importlib.util
import json
import plistlib
from unittest.mock import patch
from types import SimpleNamespace
from pathlib import Path
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'skills/remeet/scripts/content.py'
spec = importlib.util.spec_from_file_location('content_skill', SCRIPT)
content = importlib.util.module_from_spec(spec)
spec.loader.exec_module(content)

# Synthetic representative structure, not a captured user export.
HTML = '''<html><style>ignored</style><div class="memo"><div class="time">2026-09-29 10:00:00</div>
<div class="content"><p>第一段 &amp; 中文🌱 #阅读</p><p>第二段<br>新行 <a href="https://example.com">链接</a></p><img src="photo.png"></div></div>
<div class="memo"><div class="content"><p>另一条</p></div></div>
<div class="memo"><div class="content"><img src="only-image.png"></div></div></html>'''


class ContentSkillTests(unittest.TestCase):
    def test_optional_tags_survive_import_patch_and_restore(self):
        for tags in [None, '工作', ['工作', 1]]:
            with self.assertRaises(ValueError):
                content.normalize([{'text': 'A', 'tags': tags}])
        self.assertEqual(content.normalize([{'text': 'A', 'tags': [' 工作 ', '', '工作', '阅读 🌱']}]),
                         [{'text': 'A', 'tags': ['工作', '阅读 🌱']}])
        self.assertEqual(content.normalize([{'text': 'A', 'tags': []}]), [{'text': 'A'}])
        self.seed([{'text': 'A', 'tags': ['工作']}])
        content.apply_plan(content.create_plan(self.input([{'text': 'A', 'tags': ['不覆盖']}, {'text': 'B'}]), self.target, 'merge'))
        self.assertEqual(content.read_json(self.target)[0]['tags'], ['工作'])
        content.apply_plan(content.create_plan(self.input([{'old_text': 'A', 'text': 'A2'}]), self.target, 'patch'))
        self.assertEqual(content.read_json(self.target)[0]['tags'], ['工作'])
        content.apply_plan(content.create_plan(self.input([{'old_text': 'A2', 'text': 'A2', 'tags': ['阅读']}]), self.target, 'patch'))
        self.assertEqual(content.read_json(self.target)[0]['tags'], ['阅读'])
        receipt = content.apply_plan(content.create_plan(self.input([{'old_text': 'A2', 'text': 'A2', 'tags': []}]), self.target, 'patch'))
        self.assertNotIn('tags', content.read_json(self.target)[0])
        content.apply_plan(content.create_plan(receipt['backup'], self.target, 'replace'))
        self.assertEqual(content.read_json(self.target)[0]['tags'], ['阅读'])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / 'app' / 'quotes.json'
        self.incoming = self.root / 'input.json'

    def input(self, rows):
        self.incoming.write_text(json.dumps(rows, ensure_ascii=False))
        return self.incoming

    def seed(self, rows):
        self.target.parent.mkdir(exist_ok=True)
        self.target.write_bytes(content.encoded(rows))

    def test_html_and_zip_preserve_boundaries_tags_links_and_report_media(self):
        path = self.root / 'export.html'
        path.write_text(HTML)
        quotes, report = content.convert_html(path)
        self.assertEqual(len(quotes), 2)
        self.assertIn('第二段\n新行 链接 (https://example.com)', quotes[0]['text'])
        self.assertIn('#阅读', quotes[0]['text'])
        self.assertEqual(quotes[0]['source'], 'flomo · 2026-09-29 10:00:00')
        self.assertEqual(sum(x['media_not_imported'] for x in report['items']), 2)
        self.assertTrue(report['items'][2]['empty_text_skipped'])
        archive = self.root / 'export.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('nested/export.html', HTML)
            z.writestr('nested/photo.png', b'fake')
        self.assertEqual(content.convert_html(archive)[0], quotes)
        self.assertFalse((self.root / 'nested').exists())

    def test_unknown_or_ambiguous_html_fails_closed(self):
        path = self.root / 'unknown.html'
        for html in ['<p>not a memo</p>', '<div class="memo">no content</div>', '<div class="memo"><div class="content">a</div><div class="content">b</div></div>']:
            path.write_text(html)
            with self.assertRaises(ValueError): content.convert_html(path)

    def test_preformatted_note_keeps_semantic_indent_and_internal_blank_lines(self):
        code = 'if ready:\n    run()\n\n\nnext()'
        path = self.root / 'code.html'
        path.write_text('<div class="memo"><div class="content"><p>说明</p>'
                        '<pre><code>' + code + '</code></pre><p>后记</p></div></div>')
        quotes, _ = content.convert_html(path)
        self.assertIn(code, quotes[0]['text'])
        self.assertTrue(quotes[0]['text'].startswith('说明'))
        self.assertTrue(quotes[0]['text'].endswith('后记'))

    def test_json_validation_matches_app_contract(self):
        self.assertEqual(content.normalize([{'text': ' A '}, {'text': 'A'}, {'text': ' \n'}]), [{'text': 'A'}])
        for value in [{}, [{'text': 1}], [{'text': 'a', 'source': None}], [{'text': 'a', 'extra': 1}]]:
            with self.assertRaises(ValueError): content.normalize(value)

    def test_merge_preview_is_read_only_apply_backs_up_and_repeat_is_noop(self):
        self.seed([{'text': '旧', 'source': '原来源'}])
        original = self.target.read_bytes()
        self.input([{'text': '旧', 'source': '不覆盖'}, {'text': '新'}])
        plan = content.create_plan(self.incoming, self.target, 'merge')
        self.assertEqual(self.target.read_bytes(), original)
        receipt = content.apply_plan(plan)
        self.assertEqual(Path(receipt['backup']).read_bytes(), original)
        self.assertEqual(content.read_json(self.target), [{'text': '旧', 'source': '原来源'}, {'text': '新'}])
        receipt = content.apply_plan(content.create_plan(self.incoming, self.target, 'merge'))
        self.assertEqual(receipt['status'], 'unchanged')
        self.assertEqual(len(list((self.target.parent / 'import-backups').iterdir())), 1)

    def test_stale_preview_and_changed_result_are_rejected(self):
        self.seed([{'text': '旧'}])
        plan = content.create_plan(self.input([{'text': '新'}]), self.target, 'merge')
        self.seed([{'text': '用户刚改过'}])
        with self.assertRaises(ValueError): content.apply_plan(plan)
        self.assertEqual(content.read_json(self.target), [{'text': '用户刚改过'}])
        plan = content.create_plan(self.incoming, self.target, 'merge')
        plan['after'].append({'text': '额外修改'})
        with self.assertRaises(ValueError): content.apply_plan(plan)

    def test_plan_summary_preserves_metadata_changes_and_row_order(self):
        before = [{'text': 'A', 'source': '原来源', 'tags': ['工作']},
                  {'text': 'B'}, {'text': 'C'}]
        updated_a = {'text': 'A', 'source': '新来源', 'tags': ['阅读']}
        updated_b = {'text': 'B', 'source': '补充来源'}
        added = {'text': 'D'}
        cases = [
            ('merge', [updated_a, added], [added], []),
            ('replace', [before[2], updated_b, before[0], added], [updated_b, added], [before[1]]),
            ('patch', [dict(updated_a, old_text='A')], [updated_a], [before[0]]),
            ('remove', [before[1]], [], [before[1]]),
            ('replace', list(reversed(before)), [], []),
        ]
        for mode, incoming, expected_added, expected_removed in cases:
            with self.subTest(mode=mode, incoming=incoming):
                self.seed(before)
                original = self.target.read_bytes()
                plan = content.create_plan(self.input(incoming), self.target, mode)
                self.assertEqual(plan['added_or_changed'], expected_added)
                self.assertEqual(plan['removed_or_changed'], expected_removed)
                self.assertEqual(plan['summary'], {
                    'before': len(before), 'after': len(plan['after']),
                    'added_or_changed': len(expected_added), 'removed_or_changed': len(expected_removed)})
                self.assertEqual(self.target.read_bytes(), original)

    def test_patch_remove_and_backup_restore(self):
        self.seed([{'text': 'A', 'source': '来源'}, {'text': 'B'}])
        plan = content.create_plan(self.input([{'old_text': 'A', 'text': '改成多行\n内容'}]), self.target, 'patch')
        receipt = content.apply_plan(plan)
        self.assertEqual(content.read_json(self.target)[0], {'text': '改成多行\n内容', 'source': '来源'})
        content.apply_plan(content.create_plan(self.input([{'text': 'B'}]), self.target, 'remove'))
        self.assertEqual(len(content.read_json(self.target)), 1)
        content.apply_plan(content.create_plan(receipt['backup'], self.target, 'replace'))
        self.assertEqual(content.read_json(self.target), [{'text': 'A', 'source': '来源'}, {'text': 'B'}])

    def test_patch_rejects_ambiguous_or_unknown_identity(self):
        self.seed([{'text': 'A'}, {'text': 'B'}])
        for rows in [[{'old_text': 'X', 'text': 'C'}], [{'old_text': 'A', 'text': 'B'}], [{'old_text': 'A', 'text': ''}]]:
            with self.assertRaises(ValueError):
                content.create_plan(self.input(rows), self.target, 'patch')

    def test_invalid_existing_data_is_not_overwritten(self):
        self.target.parent.mkdir()
        self.target.write_text('broken json')
        with self.assertRaises(ValueError):
            content.create_plan(self.input([{'text': '新'}]), self.target, 'replace')
        self.assertEqual(self.target.read_text(), 'broken json')

    def test_new_target_and_empty_replace(self):
        content.apply_plan(content.create_plan(self.input([{'text': '首次'}]), self.target, 'merge'))
        receipt = content.apply_plan(content.create_plan(self.input([]), self.target, 'replace'))
        self.assertEqual(content.read_json(self.target), [])
        self.assertTrue(Path(receipt['backup']).exists())

    def test_renamed_and_legacy_app_use_declared_executable(self):
        for executable in ['Remeet', 'NotchRecall']:
            bundle = self.root / (executable + '.app')
            binary = bundle / 'Contents/MacOS' / executable
            binary.parent.mkdir(parents=True)
            binary.write_text('synthetic executable')
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': executable, 'NotchRecallContentReloadVersion': 1}))
            with patch.object(content.subprocess, 'run', return_value=SimpleNamespace(stdout='{"status":"reloaded"}')) as run:
                self.assertEqual(content.notify_app(bundle, self.target)['status'], 'reloaded')
                self.assertEqual(run.call_args.args[0], [str(binary), '--reload-content', str(self.target)])

    def test_invalid_executable_declaration_does_not_launch(self):
        bundle = self.root / 'invalid.app'
        (bundle / 'Contents').mkdir(parents=True)
        for executable in ['', '../outside', '/tmp/outside']:
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': executable, 'NotchRecallContentReloadVersion': 1}))
            with patch.object(content.subprocess, 'run') as run:
                self.assertEqual(content.notify_app(bundle, self.target)['status'], 'not_reloaded')
                run.assert_not_called()

    def test_older_app_is_never_launched_with_unsupported_flag(self):
        result = content.notify_app(self.root / 'missing.app', self.target)
        self.assertEqual(result['status'], 'not_reloaded')


if __name__ == '__main__':
    unittest.main()

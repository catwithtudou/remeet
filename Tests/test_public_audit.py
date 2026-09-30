import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/audit-public.py'
spec = importlib.util.spec_from_file_location('public_audit', SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class PublicAuditTests(unittest.TestCase):
    def test_detects_generated_data_and_symlinks(self):
        for path in ['build/app.txt', 'imports/export.html', 'import-runs/plan.json', '.env', 'quotes.json', 'bundle.app/code',
                     'CONTEXT.md', 'context.md', 'Remeet_MVP_SPEC.md', 'docs/product/PRODUCT_PROPOSAL.md',
                     'docs/MANUAL_ACCEPTANCE.md', 'docs/RELEASE_REVIEW.md']:
            self.assertIn('local/private/generated file', audit.findings(path, b'content'))
        self.assertIn('symlink or non-regular Git object', audit.findings('external', b'/tmp/file', '120000'))

    def test_detects_private_material_without_returning_its_value(self):
        fixtures = [('/Users/' + 'example' + '/notes', 'personal absolute path'),
                    ('ghp_' + 'a' * 36, 'access token'),
                    ('10.' + '20.30.40', 'private IPv4 address'),
                    ('https://example.' + 'internal/project', 'internal domain')]
        for value, rule in fixtures:
            self.assertIn(rule, audit.findings('note.md', value.encode()))
            self.assertNotIn(value, str(audit.findings('note.md', value.encode())))

    def test_only_reviewed_asset_bytes_and_paths_are_allowed(self):
        for path in audit.REVIEWED_ASSETS:
            with self.subTest(path=path):
                data = (SCRIPT.parents[1] / path).read_bytes()
                self.assertEqual(audit.findings(path, data), [])
                self.assertTrue(audit.findings('unreviewed/' + path, data))
                self.assertTrue(audit.findings(path, data + b'\0'))

    def test_allows_public_sources_and_synthetic_samples(self):
        self.assertEqual(audit.findings('README.md', b'https://github.com/owner/remeet'), [])
        self.assertEqual(audit.findings('quotes.example.json', '[{"text":"示例"}]'.encode()), [])
        self.assertEqual(audit.findings('.env.example', b'# put local configuration in .env'), [])


if __name__ == '__main__':
    unittest.main()

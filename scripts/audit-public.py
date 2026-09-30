#!/usr/bin/env python3
"""Audit Git's staged snapshot before public sharing; never print matched values."""
import re
import hashlib
import subprocess
from pathlib import PurePosixPath

BLOCKED_DIRS = {'.build', 'build', '.venv', '__pycache__', 'xcuserdata', 'imports',
                'import-backups', 'import-runs', 'exports', 'private', '.local', '.git'}
BLOCKED_SUFFIXES = {'.p12', '.pfx', '.pem', '.key', '.cer', '.dmg', '.zip', '.log',
                    '.pyc', '.mobileprovision', '.provisionprofile'}
LOCAL_DOCUMENTS = {'CONTEXT.md', 'context.md', 'Remeet_MVP_SPEC.md',
                   'docs/MANUAL_ACCEPTANCE.md', 'docs/RELEASE_REVIEW.md'}
# Original icon and product screenshots using synthetic notes, visually reviewed.
# Changed assets must be reviewed again before updating their digests.
REVIEWED_ASSETS = {
    'Resources/Remeet.icns': 'ce7ba9b12eaa53cba960f1bacb13c19ec6eedc7f277e7ec4c04ba28ddccd46d3',
    'docs/images/my-content.jpg': '084ee49ff159d66f5dcb5626d051dc87363aa34675c0919f5728f0ee5426644f',
    'docs/images/recall.jpg': '169f06806c63c4c33e6e89a507b8149cf181871159def26f3972b0afb283f632',
    'docs/images/settings.jpg': 'e35cf243c07f2bbd558fe4872378e14d23b85a53c94a2c1e7ddc4d611f4fb566',
    'website/dist/assets/my-content.jpg': '084ee49ff159d66f5dcb5626d051dc87363aa34675c0919f5728f0ee5426644f',
    'website/dist/assets/recall.jpg': '169f06806c63c4c33e6e89a507b8149cf181871159def26f3972b0afb283f632',
    'website/dist/assets/settings.jpg': 'e35cf243c07f2bbd558fe4872378e14d23b85a53c94a2c1e7ddc4d611f4fb566',
}
RULES = {
    'personal absolute path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'internal domain': re.compile(r'\b(?:[\w-]+\.)+(?:internal|corp|intranet)\b', re.I),
    'private IPv4 address': re.compile(r'\b(?:10|192\.168|172\.(?:1[6-9]|2[0-9]|3[01]))(?:\.\d{1,3}){2,3}\b'),
    'private key': re.compile(r'-{5}BEGIN (?:[A-Z]+ )*PRIVATE KEY-{5}'),
    'access token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16})\b'),
    'credential assignment': re.compile(r'''(?im)^\s*["']?(?:password|api[_-]?key|access[_-]?token|client[_-]?secret)["']?\s*[:=]\s*["']?[A-Za-z0-9_+/=-]{12,}'''),
}


def findings(path, data, mode='100644'):
    name = PurePosixPath(path)
    result = []
    if mode not in {'100644', '100755'}:
        result.append('symlink or non-regular Git object')
    if (set(name.parts) & BLOCKED_DIRS or any(p.endswith('.app') for p in name.parts)
            or path in LOCAL_DOCUMENTS or path.startswith('docs/product/')
            or name.suffix.lower() in BLOCKED_SUFFIXES or name.name in {'.DS_Store', 'quotes.json'}
            or (name.name.startswith('.env') and name.name != '.env.example')):
        result.append('local/private/generated file')
    if len(data) > 1024 * 1024:
        result.append('large file: review before publishing')
    if REVIEWED_ASSETS.get(path) == hashlib.sha256(data).hexdigest():
        return result
    try:
        text = data.decode('utf-8')
        if '\0' in text:
            result.append('binary content: review before publishing')
        result.extend(label for label, pattern in RULES.items() if pattern.search(text))
    except UnicodeDecodeError:
        result.append('binary content: review before publishing')
    return result


def main():
    output = subprocess.check_output(['git', 'ls-files', '--stage', '-z'])
    entries = [entry for entry in output.split(b'\0') if entry]
    if not entries:
        raise SystemExit('No staged files; nothing audited.')
    count = 0
    failed = False
    for entry in entries:
        metadata, path_bytes = entry.split(b'\t', 1)
        mode, oid, stage = metadata.decode().split()
        path = path_bytes.decode('utf-8')
        if stage != '0':
            print(f'{path}: unresolved merge entry')
            failed = True
            continue
        data = subprocess.check_output(['git', 'cat-file', 'blob', oid]) if mode != '160000' else b''
        issues = findings(path, data, mode)
        count += 1
        if issues:
            failed = True
            print(f'{path}: {", ".join(issues)}')
    print(f'{"FAIL" if failed else "PASS"}: {count} staged files checked; no matched values printed.')
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Offline content conversion and reviewable file transactions. Python 3.10+, stdlib only."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
import zipfile
from datetime import datetime, timezone
from html.parser import HTMLParser

DEFAULT_TARGET = Path.home() / 'Library/Application Support/NotchRecall/quotes.json'


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def normalize(value):
    if not isinstance(value, list):
        raise ValueError('内容必须为 JSON 数组')
    result, seen = [], set()
    for index, item in enumerate(value):
        if not isinstance(item, dict) or not isinstance(item.get('text'), str):
            raise ValueError(f'第 {index + 1} 条缺少字符串 text')
        if set(item) - {'text', 'source', 'tags'}:
            raise ValueError(f'第 {index + 1} 条含未知字段；请先转换为 text/source/tags，避免丢失元数据')
        if 'source' in item and not isinstance(item['source'], str):
            raise ValueError(f'第 {index + 1} 条 source 必须为字符串，不能为 null')
        tags = item.get('tags', [])
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise ValueError(f'第 {index + 1} 条 tags 必须为字符串数组，不能为 null')
        tags = list(dict.fromkeys(tag.strip() for tag in tags if tag.strip()))
        text = item['text'].strip()
        if not text or text in seen:
            continue
        seen.add(text)
        row = dict(item, text=text)
        row.pop('tags', None)
        if tags:
            row['tags'] = tags
        result.append(row)
    return result


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def read_target(path):
    data = path.read_bytes() if path.exists() else None
    return data, normalize(json.loads(data.decode('utf-8-sig'))) if data is not None else []


def write_new(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(encoded(value))


class Node:
    def __init__(self, tag='', attrs=()):
        self.tag, self.attrs, self.children = tag, dict(attrs), []

    def has_class(self, name):
        return name in self.attrs.get('class', '').split()

    def descendants(self):
        for child in self.children:
            if isinstance(child, Node):
                yield child
                yield from child.descendants()

    def text(self):
        if self.tag in {'script', 'style', 'img', 'audio', 'video'}:
            return ''
        if self.tag == 'br':
            return '\n'
        content = ''.join(c.text() if isinstance(c, Node) else c for c in self.children)
        if self.tag == 'a':
            href = self.attrs.get('href', '')
            if href and href != content.strip():
                content += f' ({href})'
        if self.tag in {'p', 'div', 'li', 'blockquote', 'pre', 'h1', 'h2', 'h3'}:
            return '\n' + content + '\n'
        return content


class ExportHTML(HTMLParser):
    VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node()
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def html_files(path):
    if path.is_dir():
        files = sorted(p for p in path.rglob('*') if p.suffix.lower() in {'.html', '.htm'})
        for file in files:
            yield str(file.relative_to(path)), file.read_text(encoding='utf-8-sig')
    elif zipfile.is_zipfile(path):
        # Read entries in-place; never execute HTML or extract archive paths.
        with zipfile.ZipFile(path) as archive:
            for name in sorted(archive.namelist()):
                if Path(name).suffix.lower() in {'.html', '.htm'} and not name.startswith('__MACOSX/'):
                    yield name, archive.read(name).decode('utf-8-sig')
    else:
        yield path.name, path.read_text(encoding='utf-8-sig')


def convert_html(path, memo_class='memo', content_class='content', time_class='time'):
    quotes, details = [], []
    for filename, html in html_files(path):
        parser = ExportHTML()
        parser.feed(html)
        memos = [n for n in parser.root.descendants() if n.has_class(memo_class)]
        if not memos:
            raise ValueError(f'{filename}: 没有识别到笔记边界 {memo_class!r}，请检查实际 HTML 结构')
        for index, memo in enumerate(memos):
            contents = [n for n in memo.descendants() if n.has_class(content_class)]
            if len(contents) != 1:
                raise ValueError(f'{filename} 第 {index + 1} 条: 正文边界不明确，停止转换')
            body = contents[0]
            raw = body.text()
            # ponytail: keep the whole note's whitespace when it has pre; add
            # segment-level cleanup only if mixed HTML spacing needs refinement.
            if body.tag == 'pre' or any(n.tag == 'pre' for n in body.descendants()):
                text = raw.strip()
            else:
                text = re.sub(r'\n{3,}', '\n\n', '\n'.join(line.strip() for line in raw.splitlines())).strip()
            times = [n.text().strip() for n in memo.descendants() if n.has_class(time_class)]
            date = times[0] if times and re.fullmatch(r'\d{4}-\d\d-\d\d(?:[ T]\d\d:\d\d(?::\d\d)?)?', times[0]) else ''
            media = sum(n.tag in {'img', 'audio', 'video'} for n in memo.descendants())
            details.append({'file': filename, 'item': index + 1, 'media_not_imported': media, 'empty_text_skipped': not bool(text)})
            if text:
                quotes.append({'text': text, 'source': 'flomo' + (f' · {date}' if date else '')})
    if not details:
        raise ValueError('没有找到 HTML 笔记；不生成空导入文件')
    normalized = normalize(quotes)
    return normalized, {'notes': len(details), 'output': len(normalized), 'duplicates_skipped': len(quotes) - len(normalized), 'items': details}


def create_plan(input_path, target, mode):
    target = Path(target).expanduser().resolve()
    before_data, before = read_target(target)
    raw = read_json(input_path)
    if mode == 'patch':
        if not isinstance(raw, list):
            raise ValueError('patch 必须为操作数组')
        by_text = {q['text']: dict(q) for q in before}
        seen = set()
        for item in raw:
            if not isinstance(item, dict) or not isinstance(item.get('old_text'), str) or not isinstance(item.get('text'), str):
                raise ValueError('patch 条目需要字符串 old_text 和 text，可选 source 和 tags')
            if set(item) - {'old_text', 'text', 'source', 'tags'}:
                raise ValueError('patch 含未知字段')
            old = item['old_text'].strip()
            if old in seen or old not in by_text:
                raise ValueError('patch 的 old_text 不存在或重复，请重新生成预览')
            if not item['text'].strip():
                raise ValueError('patch 不允许空正文；删除请使用 remove 模式')
            seen.add(old)
            by_text[old]['text'] = item['text'].strip()
            if 'source' in item:
                by_text[old]['source'] = item['source']
            if 'tags' in item:
                by_text[old]['tags'] = item['tags']
        candidate = list(by_text.values())
        after = normalize(candidate)
        if len(after) != len(candidate):
            raise ValueError('patch 将造成正文冲突，请明确合并或删除方案')
    else:
        incoming = normalize(raw)
        if mode == 'merge':
            after = normalize(before + incoming)
        elif mode == 'replace':
            after = incoming
        elif mode == 'remove':
            removed = {q['text'] for q in incoming}
            if not removed <= {q['text'] for q in before}:
                raise ValueError('删除目标包含不存在的正文，请重新生成预览')
            after = [q for q in before if q['text'] not in removed]
        else:
            raise ValueError('未知模式')
    added = [q for q in after if q not in before]
    removed = [q for q in before if q not in after]
    return {'version': 1, 'target': str(target), 'base_sha256': digest(before_data), 'mode': mode,
            'before': before, 'after': after, 'result_sha256': digest(encoded(after)),
            'summary': {'before': len(before), 'after': len(after), 'added_or_changed': len(added), 'removed_or_changed': len(removed)},
            'added_or_changed': added, 'removed_or_changed': removed}


def apply_plan(plan):
    if plan.get('version') != 1 or plan.get('mode') not in {'merge', 'replace', 'remove', 'patch'}:
        raise ValueError('不支持的计划格式')
    target = Path(plan['target']).expanduser().resolve()
    result = normalize(plan['after'])
    if digest(encoded(result)) != plan['result_sha256']:
        raise ValueError('预览结果已变化，请重新生成计划')
    current, _ = read_target(target)
    if digest(current) != plan['base_sha256']:
        raise ValueError('目标文件在预览后已变化，未写入；请重新生成计划')
    if normalize(plan['before']) == result:
        return {'status': 'unchanged', 'target': str(target), 'count': len(result), 'backup': None}
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if current is not None:
        backup_dir = target.parent / 'import-backups'
        backup_dir.mkdir(exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        backup = backup_dir / f'quotes-{stamp}-{uuid.uuid4().hex[:8]}.json'
        with backup.open('xb') as stream:
            stream.write(current)
    # Recheck immediately before replace. The editor also checks its baseline on save.
    descriptor, temporary = tempfile.mkstemp(prefix='.remeet-import-', dir=target.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(encoded(result))
            stream.flush()
            os.fsync(stream.fileno())
        latest = target.read_bytes() if target.exists() else None
        if digest(latest) != plan['base_sha256']:
            raise ValueError('目标在写入前发生变化；请重新生成计划')
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {'status': 'written', 'target': str(target), 'count': len(result), 'backup': str(backup) if backup else None, 'sha256': digest(target.read_bytes())}


def notify_app(app, target):
    bundle = Path(app).expanduser()
    try:
        with (bundle / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
            supported = info.get('NotchRecallContentReloadVersion') == 1
            executable = info.get('CFBundleExecutable')
    except (OSError, ValueError, plistlib.InvalidFileException):
        supported = False
    if not supported:
        return {'status': 'not_reloaded', 'reason': '此应用未声明重载协议 v1；请更新应用或从菜单重新加载内容'}
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        return {'status': 'not_reloaded', 'reason': '应用可执行文件声明无效；请从菜单重新加载内容'}
    binary = bundle / 'Contents/MacOS' / executable
    if not binary.is_file():
        return {'status': 'not_reloaded', 'reason': '未找到应用可执行文件；请从菜单重新加载内容'}
    try:
        call = subprocess.run([str(binary), '--reload-content', str(target)], capture_output=True, text=True, timeout=6)
        return json.loads(call.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        return {'status': 'not_reloaded', 'reason': str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    convert = sub.add_parser('convert')
    convert.add_argument('input', type=Path)
    convert.add_argument('--format', choices=['flomo-html', 'json'], required=True)
    convert.add_argument('--output', required=True)
    convert.add_argument('--report', required=True)
    for name, default in [('memo', 'memo'), ('content', 'content'), ('time', 'time')]:
        convert.add_argument(f'--{name}-class', default=default)
    plan = sub.add_parser('plan')
    plan.add_argument('input')
    plan.add_argument('--target', default=str(DEFAULT_TARGET))
    plan.add_argument('--mode', choices=['merge', 'replace', 'remove', 'patch'], default='merge')
    plan.add_argument('--output', required=True)
    apply = sub.add_parser('apply')
    apply.add_argument('plan')
    apply.add_argument('--app', help='Optional .app path; request and acknowledge a live reload')
    args = parser.parse_args()
    try:
        if args.command == 'convert':
            if args.format == 'flomo-html':
                result, report = convert_html(args.input, args.memo_class, args.content_class, args.time_class)
            else:
                raw = read_json(args.input)
                result = normalize(raw)
                report = {'input': len(raw), 'output': len(result), 'blank_or_duplicate_skipped': len(raw) - len(result)}
            write_new(args.output, result)
            write_new(args.report, report)
            summary = {key: value for key, value in report.items() if key != 'items'}
            if 'items' in report:
                summary['media_not_imported'] = sum(item['media_not_imported'] for item in report['items'])
                summary['empty_text_skipped'] = sum(item['empty_text_skipped'] for item in report['items'])
            print(json.dumps(summary, ensure_ascii=False))
        elif args.command == 'plan':
            result = create_plan(args.input, args.target, args.mode)
            write_new(args.output, result)
            print(json.dumps(result['summary'], ensure_ascii=False))
        else:
            plan = read_json(args.plan)
            receipt = apply_plan(plan)
            if args.app:
                receipt['app'] = notify_app(args.app, Path(plan['target']))
            else:
                receipt['app'] = {'status': 'not_requested', 'action': '请从菜单重新加载内容，或在下次启动时生效'}
            print(json.dumps(receipt, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f'错误：{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

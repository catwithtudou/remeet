#!/usr/bin/env python3
"""Install the repository skill without replacing an existing installation."""
import os
from pathlib import Path
import shutil

source = Path(__file__).resolve().parents[1] / 'skills/remeet'
root = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')) / 'skills'
target = root / source.name
if target.exists() or target.is_symlink():
    raise SystemExit(f'已存在，未覆盖：{target}\n请先比较并备份现有 Skill 后再更新。')
root.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, target, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
print(f'已安装：{target}\n刷新 Skill 列表或新开会话后，使用 $remeet。')

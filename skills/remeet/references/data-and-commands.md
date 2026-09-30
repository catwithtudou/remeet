# 数据契约与命令

应用数据：UTF-8 JSON 数组，每项必须有字符串 `text`，可选 `source` 必须为字符串，`tags` 必须为字符串数组（均不可为 null）。标签去首尾空白、去空项、按完整名称区分大小写去重并保留顺序；无标签时省略 `tags`，界面归“默认”。正文去首尾空白、跳过空白、按正文去重且第一条及其来源和标签优先；内部换行与 Unicode 保留。脚本对未知字段报错，避免把其他格式误当应用数据而丢弃元数据。

```json
[
  {"text": "先验证问题，再优化方案。", "source": "flomo · 2026-09-29 10:00:00", "tags": ["思考"]},
  {"text": "多行内容\n仍属于同一条笔记。"}
]
```

以下命令中的 `SKILL_DIR` 是当前 SKILL.md 所在目录，`WORK_DIR` 为任务输出目录，`INPUT_FILE` 为用户提供的文件路径。变量名用于示例，执行前赋予真实路径。每轮用新输出名；转换器和预览器不覆盖已有产物。

```sh
python3 "$SKILL_DIR/scripts/content.py" convert "$INPUT_FILE" \
  --format flomo-html --output "$WORK_DIR/candidates.json" --report "$WORK_DIR/conversion.json"

python3 "$SKILL_DIR/scripts/content.py" plan "$WORK_DIR/candidates.json" \
  --target "$HOME/Library/Application Support/NotchRecall/quotes.json" \
  --mode merge --output "$WORK_DIR/plan.json"

python3 "$SKILL_DIR/scripts/content.py" apply "$WORK_DIR/plan.json" \
  --app "$HOME/Applications/Remeet.app"
```

App 位置不是固定的，需先核实；也可能在 `/Applications` 或开发目录。省略 `--app` 仅写文件。工具检查 Info.plist 的 `NotchRecallContentReloadVersion = 1` 后才调用程序，避免旧版不识别参数而启动第二个实例。支持版本从 0.2.4 开始：

```sh
"/实际位置/Remeet.app/Contents/MacOS/Remeet" --reload-content \
  "$HOME/Library/Application Support/NotchRecall/quotes.json"
```

回执 `reloaded` 表示相同数据路径的运行实例已成功读取；`reload_failed`、`not_acknowledged`、`not_reloaded` 都不代表已生效。文件成功写入后即便重载失败也不自动回滚，下次启动或菜单重载仍可读取。启动失败/未运行不应循环尝试。

## patch 输入

```json
[
  {"old_text": "原来的整条正文", "text": "更新后的整条正文", "source": "手工整理"}
]
```

用 `plan --mode patch`。可选 `tags` 为目标标签数组，省略时保留已有标签，传 `[]` 清空；来源同样在省略时保留。`remove` 输入仍是 `[{"text":"准确旧正文"}]`。若旧正文出现外部变化，重新建立映射，不能猜测对应关系。

仅整理标签时，`text` 仍然必填并保持原文。假设原标签为 `["工作","待整理"]`，将“待整理”改成“阅读”，同时保留“工作”：

```json
[
  {"old_text": "原来的整条正文", "text": "原来的整条正文", "tags": ["工作", "阅读"]}
]
```

省略 `source` 可保留原来源。为多条笔记生成操作时，分别读取各自的标签集合，不用同一个数组覆盖所有命中项。标签能力需要 0.2.14+ App 和带 tags 支持的 helper；旧编辑器保存可能丢失未知字段。

## 备份与恢复

每次实际改变已有文件时，在目标同级 `import-backups/` 保存原始字节备份。无变化的 merge 不写文件、不增加备份。预览记录文件摘要，应用前再次比较，普通并发编辑被检测后停止；文件协议不是跨进程数据库事务，避免同时运行多个导入任务。

恢复使用已核实的备份文件作为 `plan` 输入，模式为 `replace`，目标仍为正式 quotes.json。先审查将覆盖的当前内容，再执行 apply。备份本身不修改。首轮创建不存在的目标时无旧文件备份。

`replace` 恢复要求当前目标仍是合法内容 JSON。损坏文件无法生成该预览；先保留损坏文件与有效备份，在独立路径核对修复候选，再按明确授权处理原文件，不删掉目标来绕过检查。

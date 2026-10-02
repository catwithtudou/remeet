# 开发与验证

App 使用 Swift 6、SwiftUI 和 AppKit，最低部署目标为 macOS 14。`Sources/RemeetCore` 放置数据、调度与展示状态，`Sources/Remeet` 负责窗口和系统集成。Swift Package 与 Xcode 工程共用源码。

## 构建

```sh
./scripts/build-app.sh release
REMEET_APP_OUTPUT="$PWD/build/debug-candidate/Remeet.app" ./scripts/build-app.sh debug
```

默认输出为 `build/Remeet.app`，已有输出会被拒绝。重复构建时设置 `REMEET_APP_OUTPUT` 指向新目录，保留旧包用于回退。脚本使用 SwiftPM native 后端，可在 Command Line Tools 环境构建。

Release 副本在签名前移除调试符号；SwiftPM 原始产物保留供调试。当前为本机架构构建和 ad-hoc 签名，不生成 Universal 包，也不进行 Developer ID 签名或公证。分发步骤见[发布说明](RELEASING.md)。

`Remeet.xcodeproj` 是 Xcode 工程目录，记录源码、资源、构建配置和运行方案，是开发所需的共享文件。普通用户下载 Release 的 App 即可，无需打开它。完整 Xcode 可打开该工程，选择 `Remeet` / `My Mac`，或运行：

```sh
xcodebuild -project Remeet.xcodeproj -scheme Remeet \
  -configuration Debug -derivedDataPath build/DerivedData build
```

仅安装 Command Line Tools 时，可补充检查单模块编译方式；此检查不等于 Xcode archive：

```sh
xcrun swiftc -typecheck -parse-as-library -swift-version 6 \
  -target arm64-apple-macosx14.0 Sources/RemeetCore/*.swift Sources/Remeet/*.swift
plutil -lint Resources/Info.plist Remeet.xcodeproj/project.pbxproj
```

## 测试

```sh
./scripts/test.sh
REMEET_TEST_BINARY=.build/debug/Remeet python3 -m unittest discover -s Tests -v
```

Swift 使用 Swift Testing，脚本补齐部分 CLT 版本所需的 framework 路径。原生窗口测试需要已登录的图形会话；仅运行无窗口逻辑可加 `--skip NativeWindowTests`。

Python 3.10+ 测试使用标准库、临时目录和构造数据。`REMEET_TEST_BINARY` 启用独立数据目录/偏好域的重载验证；不设置时跳过此项。这里必须使用 Debug 二进制，Release 不接受隔离环境变量。

自动化覆盖数据校验、保存冲突、标签、调度、窗口几何及导入/恢复。真实刘海位置、焦点、锁屏唤醒、不同显示器和下载安装体验仍需实机检查。

[GitHub Actions](https://github.com/catwithtudou/remeet/actions/workflows/ci.yml) 在推送到 main 或提交 PR 时，运行公开文件审计、Swift/Python 测试和 Release 打包检查。成功后保留与提交 SHA 对应的 App ZIP 产物 14 天；面向用户的长期下载位于 [Releases](https://github.com/catwithtudou/remeet/releases)。

## 隔离运行

先创建独立目录并放入示例 `quotes.json`，再运行 Debug 包：

```sh
REMEET_DATA_DIR="$PWD/build/qa-data" \
REMEET_DEFAULTS_SUITE=local.Remeet.qa \
build/debug-candidate/Remeet.app/Contents/MacOS/Remeet --settings
```

路径需对应实际 Debug 包。`--preview` 展开当前内容，调试菜单的“模拟定时触发”复用定时处理，不修改系统时间。不要用真实笔记拍摄公开配图。

## 内容与兼容约定

UTF-8 JSON 数组，每项有字符串 `text`，可选字符串 `source` 和字符串数组 `tags`；可选字段不能为 null。例如：

```json
[
  {"text": "先理解问题，再讨论方案。", "source": "示例", "tags": ["工作"]},
  {"text": "给自己留一点空白。"}
]
```

正文去首尾空白、跳过空项，同正文保留第一条及其来源和标签。标签去首尾空白、空项和重复项，名称区分大小写并保留首次顺序；缺省或空数组归“默认”，保存时省略空 tags。非法文件整体拒绝，保留此前有效数据；合法空数组清空内容池。编辑保存采用原子写入和文件基线冲突检查。

以下旧标识用于升级兼容，不随产品改名变更：

- `local.NotchRecall`：Bundle ID 与标准 UserDefaults 偏好域。
- `~/Library/Application Support/NotchRecall/quotes.json`：用户内容路径。
- `local.NotchRecall.reloadContent` / `reloadContentReply`、`NotchRecallContentReloadVersion`：本机重载协议。

可执行文件名从 Info.plist 的 `CFBundleExecutable` 读取。0.2.14 起支持 tags，旧数据无需迁移；带标签内容须使用对应新版 App 和 helper，旧编辑器保存时可能丢失未知字段。

### 内容选择与展示

编辑器筛选与随机内容池独立，搜索和切换不会写文件；保存作用于全部草稿。新增笔记重置筛选，未提交的标签输入也参与保存与关闭保护。

删除撤销只恢复被删除的草稿及其原位置、来源、标签和未提交标签输入，不回退其他条目的编辑；恢复选中项时清空筛选。保存成功、重新载入成功或放弃草稿会清空删除撤销记录，失败则保留。正文输入框仍使用原生撤销，删除使用独立的“撤销删除”按钮。

App 修改已有文件前，将原始字节保存在同一数据目录的 `editor-backups/`，最多保留 10 份；首次创建和内容字节未改变时不新增备份。备份创建或轮换失败时拒绝保存，保留草稿、磁盘文件与原内容池。备份后再次核对文件基线；原子替换与基线检查不构成跨进程写锁。

“恢复备份”在窗口打开时读取备份列表。内容文件可正常载入时，可将备份载入为编辑草稿；有未保存修改则先确认。坏备份读取失败不替换草稿。恢复只在显式保存后生效，沿用文件冲突检查、保存前备份和关闭保护，不自动展示或重排计划。文件损坏且无法载入时仍需按[内容恢复说明](CONTENT_IMPORT.md)保留原件并修复。App 备份与 helper 的 `import-backups/` 相互独立，App 不轮换导入备份。

“预览这条”只展示选中的已保存笔记，不改变随机条目或计划。“立即回顾”保留随机条目，“换一条回顾”更换后展示。暂停展示会阻止自动、悬停和手动展开，但定时选择继续进行。

### 调度与偏好

`frequencyMinutes` 的 30/60/120 对应按本机时钟对齐的预设，0 表示自定义；`customIntervalMinutes` 范围为 1–1440，`readingSeconds` 为 1–3600。旧偏好默认值保持兼容。

自定义间隔从启动或应用设置时起算，正常回调延迟不累积，睡眠恢复跳过错过的周期。时钟回退到起算点之前时重新起算；预设保留绝对时刻去重。手动回顾不改变定时计划。

### 本机重载

支持版本在 Info.plist 声明 `NotchRecallContentReloadVersion = 1`：

```sh
build/Remeet.app/Contents/MacOS/Remeet --reload-content '/实际数据目录/quotes.json'
```

该命令不启动 UI，通过同一用户的 DistributedNotificationCenter 请求重载并等待回执，只匹配 App 自身的数据路径。`reloaded` 表示已读取，不表示已经展示；没有匹配实例时返回 `not_acknowledged`。重载不会自动展开或改变计划，未保存草稿仍受文件冲突保护。

## Skill 本地安装

仓库附带 `skills/remeet`。在已有 Python 3.10+ 的开发环境中，可从仓库根目录安装至 Codex：

```sh
python3 scripts/install-skill.py
```

已有同名目录时脚本拒绝覆盖，先比较并保留旧版本再更新。其他 Agent 可按其 Skills 约定加载该目录，也可使用 README 中的 `npx skills add catwithtudou/remeet --skill remeet -g` 命令。App 本身不依赖 Python、Node.js 或 Agent。

## 图标与文档配图

App、菜单栏与刘海标识复用 `Sources/Remeet/RemeetArtwork.swift`。生成 App 图标：

```sh
mkdir -p build
swiftc Sources/Remeet/RemeetArtwork.swift scripts/generate-icon.swift -o build/generate-icon
build/generate-icon build/icon-assets
iconutil -c icns build/icon-assets/Remeet.iconset -o Resources/Remeet.icns
```

`docs/images/overview.svg` 为场景示意，内容与设置图片来自隔离 Debug 实例。更新时仅使用明确标注的示例笔记，检查界面、文字和裁切后再替换。`scripts/audit-public.py` 固定已审阅二进制资产的摘要，图片变更后须重新审阅并同步摘要。

仓库保留源码、测试、示例和可复用文档；本机上下文、需求讨论稿、验收流水、导入材料及构建产物由 `.gitignore` 排除。公开前检查实际 Git 索引，避免只改忽略规则而遗留已暂存文件。

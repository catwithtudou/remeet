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

脚本也会在存在 `lib_TestingInterop.dylib` 时补齐其运行库路径。若测试尚未开始就报 `PackageDescription` 链接错误，先用临时空 Swift Package 复现，检查 CLT 安装是否混用了不同版本的 `.swiftinterface` 和动态库；不要通过改业务代码或降低 Swift 版本掩盖工具链问题。

Python 3.10+ 测试使用标准库、临时目录和构造数据。`REMEET_TEST_BINARY` 启用独立数据目录/偏好域的重载验证；不设置时跳过此项。这里必须使用 Debug 二进制，Release 不接受隔离环境变量。

重载集成测试还覆盖首次启动创建示例，以及重启时保留合法空文件、损坏文件和无标签旧格式。可额外构建历史版本，验证旧进程退出后替换为当前二进制，内容、偏好、备份和草稿导出不被覆盖：

```sh
legacy_root=$(mktemp -d "${TMPDIR:-/tmp}/remeet-legacy.XXXXXX")
git archive v0.2.14 | tar -x -C "$legacy_root"
swift build --package-path "$legacy_root" --build-system native -c debug
legacy_binary="$(swift build --package-path "$legacy_root" --build-system native -c debug --show-bin-path)/Remeet"
REMEET_TEST_BINARY=.build/debug/Remeet REMEET_TEST_OLD_BINARY="$legacy_binary" \
  python3 -m unittest discover -s Tests -v
```

需先运行 Swift 测试生成当前 Debug 二进制；未设置 `REMEET_TEST_OLD_BINARY` 时仅跳过历史版本替换用例。两个进程均使用临时 App 包、同一个隔离数据目录和独立偏好域；这验证进程替换与文件兼容，不代替跨机下载安装、真实登录启动或界面验收。

自动化覆盖数据校验、保存冲突、标签、调度、窗口几何及导入/恢复。真实刘海位置、焦点、锁屏唤醒、不同显示器和下载安装体验仍需实机检查。

### 稳定性维护验收

每轮维护先运行上面的完整测试，再运行 Release 构建和[打包校验](RELEASING.md)。网站同步检查 `python3 website/check.py` 和 `node --check website/dist/site.js`。测试使用临时目录和独立偏好域，不使用真实笔记。发布前审计暂存区，未暂存的修改不在 `audit-public.py` 的检查范围内。

`NativeWindowTests.contentScaleRoundTrip` 用 100、1,000、10,000 条合成笔记验证编辑器载入、搜索和标签、混合重复项导入、备份、导出、重新打开和重复导入不改写文件。它随完整测试运行，也可单独运行：

```sh
./scripts/test.sh --filter contentScaleRoundTrip
```

输出的耗时是 Debug 模式下单次操作的诊断基线，包含断言开销，不是 Release 性能承诺，也不等于界面渲染或输入延迟。比较性能时使用相同机器、构建配置与数据规模，多次采样；CI 不用固定毫秒阈值判断成败。

`workspaceRecoveryHonorsAllInactiveReasonsAndPause` 通过进程内的工作区通知验证多种停用原因叠加、暂停状态保留、显示器通知后收起、关闭后不重新启动定时器，以及模型释放。它不发送系统级锁屏通知，也不改变机器的睡眠或登录状态。

自动化通过后，使用隔离 Debug 实例补充以下实机验收，并分别记录“通过 / 失败 / 未测”：

| 场景 | 检查结果 |
| --- | --- |
| 完整编辑流程 | 新增、标签、搜索、保存、重开、撤销删除、恢复备份、导入导出后的内容一致 |
| 草稿与外部修改 | 关闭或退出时取消不丢草稿；外部改写后保存拒绝覆盖，草稿导出可保留修改 |
| 显示与焦点 | 有/无刘海、不同缩放、全屏与多显示器切换；卡片不抢焦点，悬停和移出行为正确 |
| 睡眠与锁屏 | 恢复后不补播、不意外展开，下一次计划有效；暂停状态仍保留 |
| 登录启动 | 独立 Bundle ID 下实际登录后启动、关闭后不再启动；系统拒绝时状态和提示一致 |
| 安装与升级 | 另一台 Mac 从真实下载入口安装；升级保留旧笔记、标签、偏好和备份 |
| 常驻表现 | Release 长时间空闲与多次打开/关闭后检查 CPU、内存和窗口残留 |

至少记录 macOS 版本、架构和显示器条件。最低支持 macOS 14、CI 的 macOS 15 和本机验证是不同证据，不能相互替代。模拟通知、窗口几何测试或登录项接口回读不算真实睡眠、显示器切换或登录验收。

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

0.2.17 起，「我的内容 → 导入 JSON」使用原生文件选择器，只接受本地内容 JSON，不需要 Python。`QuoteStore.previewImport` 复用读取校验与规范化规则，逐条显示新增、重复和空白，非法字段类型或格式整体拒绝。与 App 原有读取一致，未知字段忽略；helper 仍对未知字段报错。

有未保存草稿时阻止导入，保留草稿、未提交标签和删除撤销记录；可先保存，或导出草稿后重新载入。预览固定源文件字节和目标文件基线，确认时重新核对两者及编辑会话，发生变化或读取失败则保留预览并拒绝写入。返回后处理变化、重新预览，不自动覆盖外部内容。取消预览不改草稿、筛选、磁盘或内容池。

确认导入仅追加新正文，重复项保留已有条目或输入第一条的来源和标签。空数组、全空白和全重复不会清空内容、改写文件或新增备份。实际新增复用 `saveContent` 的原始字节备份、原子保存和内容池更新，沿用最近 10 份 `editor-backups/`；首次创建无旧文件备份。导入不会主动展开卡片或改变回顾计划。源文件检查和目标基线检查不构成跨进程写锁。

编辑器筛选与随机内容池独立，搜索和切换不会写文件；保存作用于全部草稿。新增笔记重置筛选，未提交的标签输入也参与保存与关闭保护。

读取、保存和保存前提示共用 `QuoteStore.normalize` 的空白过滤、正文首尾清理及同正文保留第一条规则。保存会列出全部草稿中被忽略条目的原始序号、正文、来源和标签，不受搜索或标签筛选影响；未提交标签输入也包含在提示中。普通保存、⌘S、关闭窗口保存、退出保存均通过同一确认入口；返回编辑不创建备份或写文件，并保留草稿、撤销记录及筛选。确认期间草稿发生变化时拒绝保存，外部文件变化仍由原有冲突检查拒绝覆盖。没有被忽略条目时不增加确认步骤；来源与标签不会自动合并。

删除撤销只恢复被删除的草稿及其原位置、来源、标签和未提交标签输入，不回退其他条目的编辑；恢复选中项时清空筛选。保存成功、重新载入成功或放弃草稿会清空删除撤销记录，失败则保留。正文输入框仍使用原生撤销，删除使用独立的“撤销删除”按钮。

App 修改已有文件前，将原始字节保存在同一数据目录的 `editor-backups/`，最多保留 10 份；首次创建和内容字节未改变时不新增备份。备份创建或轮换失败时拒绝保存，保留草稿、磁盘文件与原内容池。备份后再次核对文件基线；原子替换与基线检查不构成跨进程写锁。

“恢复备份”在窗口打开时读取备份列表。内容文件可正常载入时，可将备份载入为编辑草稿；有未保存修改则先确认。坏备份读取失败不替换草稿。恢复只在显式保存后生效，沿用文件冲突检查、保存前备份和关闭保护，不自动展示或重排计划。文件损坏且无法载入时仍需按[内容恢复说明](CONTENT_IMPORT.md)保留原件并修复。App 备份与 helper 的 `import-backups/` 相互独立，App 不轮换导入备份。

0.2.17 起，“导出已保存 JSON”使用 `NSSavePanel` 选择目标，在选定后重新读取并校验磁盘上的 `quotes.json`，原样原子写入导出文件，不重新编码、不使用编辑草稿或内存内容池。磁盘文件缺失、不可读或格式错误均报错；有效 `[]` 可以导出。目标路径解析符号链接后不能与源文件相同，已有目标同时按文件资源标识排除硬链接。覆盖已有导出文件由系统保存面板确认。此操作不改草稿、文件基线、删除撤销、备份、保存错误、回顾计划或内容池；外部改写仍会触发之后的保存冲突。导出与源文件更新不构成跨进程事务。

有未保存修改时显示“导出草稿”。全部草稿以 UTF-8 JSON 数组另存至数据目录的 `draft-exports/Remeet-draft-<UUID>.json`，不受列表筛选影响；每次新建文件，不覆盖已有导出，不参与备份轮换。正文保留首尾空白，空白条目和重复正文均保留，未提交标签输入按现有标签规则写入 `tags`。普通保存或导入仍按内容契约过滤空白、去重，因此导出副本应先对照最新文件再决定如何恢复，不能直接全量覆盖外部新增内容。

导出成功或失败均不修改草稿、删除撤销记录、文件基线、内容池、计划或保存冲突提示；成功后仍为未保存状态，关闭和重新载入仍须按原有保护流程处理。“查看文件”显示最近一次成功导出的副本；重新载入后保留此入口，继续编辑后的修改需再次导出。导出错误单独展示，不掩盖原保存错误。

“预览这条”只展示选中的已保存笔记，不改变随机条目或计划。“立即回顾”保留随机条目，“换一条回顾”更换后展示。暂停展示会阻止自动、悬停和手动展开，但定时选择继续进行。

### 调度与偏好

0.2.16 起，「登录时启动」使用 [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice) 注册主 App，不新增 helper、LaunchAgent 或偏好键，也不在启动时自动注册。`LoginItemController` 每次操作后读取系统状态；只有 `enabled` 显示为开启，`requiresApproval` 显示为关闭并引导到系统登录项设置，不重复注册系统已禁用的项目。注册/取消失败显示错误并保留系统实际状态。设置页出现、窗口获得焦点、App 恢复活跃时重新读取状态。

登录启动沿用现有启动流程，不主动展开卡片或恢复暂停，不改变已保存的内容和调度设置。自定义间隔仍从启动时重新起算。单元测试注入状态读写回调，避免更改测试机器的真实登录项；实际注册测试须使用独立 Bundle ID 并验证取消后为 `notRegistered`。真实登录后自动启动需另行验收，接口注册成功不等于该场景通过。

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

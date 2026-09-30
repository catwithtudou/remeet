# 打包与发布

当前分发方式为 **App ZIP → 解压 → 拖入“应用程序” → 首次手动允许打开**。App 使用 ad-hoc 本地签名，未经过 Developer ID 签名或 Apple 公证。README 和 Release 说明必须明确这一状态及首次打开步骤；正式签名、公证和 DMG 可后续补充，不作为当前版本发布的前置条件。

## 发布前检查

- 确定真实仓库地址、源码版本与发布范围；开源许可证由维护者选择，没有 LICENSE 时不宣称已提供开源授权。
- 核对支持的系统和架构。当前构建面向 Apple Silicon，最低部署目标为 macOS 14；Release 中列出实际测试的系统版本，不将最低目标等同于所有版本均已测试。
- 验证添加、保存、重开、标签筛选、手动与定时回顾、暂停和草稿保护；说明已知的显示器或系统兼容限制。
- 在另一台 Mac 从真实下载入口获取 ZIP，检查解压、移动到 Applications、首次手动允许、启动以及升级保留数据。未完成时明确标记，不能把本机构建启动当作下载验证。
- 源码中不包含个人笔记、导出、备份、本机上下文和构建产物。图片仅使用示例内容。

## 生成安装包

更新 `Resources/Info.plist` 中的版本与 build；不要覆盖已有候选包。在仓库根目录运行：

```sh
./scripts/test.sh
REMEET_TEST_BINARY=.build/debug/Remeet python3 -m unittest discover -s Tests -v

export REMEET_APP_OUTPUT="$PWD/build/release-candidate/Remeet.app"
./scripts/build-app.sh release
./scripts/package-release.sh
```

输出目录必须尚不存在，重复构建时更换目录名。脚本验证本地签名完整性、检查二进制构建路径，并生成 `build/releases/Remeet-<版本>-<架构>.zip` 及其 `.sha256` 文件。测试版状态使用 GitHub 预发布标记，签名与公证状态写在 Release 说明中。脚本不公证或自动上传。

发布前解压 ZIP，核对版本与文件内容，并从归档目录验证校验值：

```sh
shasum -a 256 -c Remeet-<版本>-<架构>.zip.sha256
```

## Release 内容

通过本仓库 Releases 上传 **App ZIP 和 SHA-256 文件**，不要将 GitHub 自动生成的 Source code ZIP/TAR 当成安装包。新建 Release 时对应真实源码标签；公开下载就绪后，将 README 的下载入口链接到该 Release。

说明中包含：

- 版本、支持架构、实际测试的 macOS 版本。
- 功能变化及已知限制。
- 未经 Developer ID 签名和 Apple 公证；首次打开按 README 进入系统设置，单独允许此 App。
- 安装、升级保留内容的方法和反馈入口。

首次测试分发可使用 GitHub 的预发布标记。仓库或附件尚未就绪时，不写成已发布，也不填写猜测的下载链接。

macOS 的手动允许流程见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。若遇到文件损坏、恶意软件提示或管理策略限制，应检查具体原因，不将所有拦截都归为未公证，也不要求用户关闭整个 Gatekeeper 或运行移除隔离属性的命令。

## 源码检查

```sh
git diff --cached --check
python3 scripts/audit-public.py
git diff --cached --stat
```

审计针对暂存区，检查本地文件、个人路径、常见凭证特征及未审阅的二进制资产。新增产品图片须先检查内容，再更新脚本中对应的资产摘要。修改 `.gitignore` 不会移除已暂存文件，需要同步调整 Git 索引。

可选 Skill 与 App 独立。对外提供 Skill 安装命令前，核实仓库地址，并验证安装和实际调用；当前 helper 需要 Python 3.10+，不能宣称 App 也需要 Python。

# 参与回见 · Remeet

构建与测试见 [开发说明](docs/DEVELOPMENT.md)，用户操作见 [README](README.md)，打包与分发见 [发布说明](docs/RELEASING.md)。

## 提交改动

- 围绕具体问题做小范围修改，复用现有 SwiftUI、AppKit 和标准库能力。
- 行为变化应有对应验证；涉及旧数据或偏好时，先核对开发说明中的兼容约定。
- 界面变化同步更新使用说明和产品图；图片使用示例内容，生成方式见开发说明。
- 源码、测试、文档和 Skill 可提交；个人笔记、导出、备份、构建包及本地工作记录不进入仓库。

提交前运行相关测试，并检查实际暂存内容：

```sh
git diff --cached --check
python3 scripts/audit-public.py
```

自动化检查通过后，仍应验证受影响的实际交互。安装包通过 Releases 分发，不提交到源码树。

# 回见产品网站

静态产品介绍与使用指南，无构建步骤或运行时依赖。公开地址：<https://catwithtudou.github.io/remeet/>。

- `dist/index.html`：产品介绍、示例交互、下载与 FAQ。
- `dist/guide.html`：安装、第一次回顾、设置与内容导入。
- `dist/assets/`：来自产品仓库的示例截图与品牌图标。
- `../.github/workflows/pages.yml`：校验与 GitHub Pages 自动部署。

在此目录启动本地预览：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist
```

校验：

```sh
python3 check.py
node --check dist/site.js
```

产品行为与安装说明以产品仓库 README 和当前发行版为准。发布更新时检查系统要求、安装限制、菜单文案与导入方式；下载链接统一指向 GitHub Releases，避免固定旧版本附件。

首页交互仅使用示例笔记，不读写用户内容。截图为真实 App 界面，演示与截图在页面内分别标注。

## 发布

网站源码与 App 共用此仓库。网站相关改动推送到 `main` 后，Website 工作流校验链接、JavaScript 语法和公开文件，再将 `website/dist` 部署到 GitHub Pages。PR 只运行校验，不部署；也可从 Actions 手动运行 Website 工作流。

仓库 Settings → Pages 的发布来源使用 GitHub Actions。页面链接与资源地址保持相对路径，以兼容 `/remeet/` 项目站点路径。只发布 `dist` 中的网页和资源，不包含维护脚本或仓库其他文件。

App 安装包继续由 GitHub Releases 分发。App 构建不依赖网站；网站发布不会生成或替换 App 发行版。

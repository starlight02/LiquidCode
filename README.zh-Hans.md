# LiquidCode

<p align="center">
  <img src="docs/assets/liquidcode-screenshot.png" alt="LiquidCode 应用截图" width="960">
</p>

LiquidCode 是 Claude Code 的原生 macOS 客户端。它把 CLI 放进一个像样的桌面应用里：左侧管理项目和会话，中间直接聊天，Provider、MCP、Skills 和
CLI 安装/登录/修复都放进设置页，不用再到处翻 dotfiles。

## 配置

- 首次启动会引导你完成 Claude CLI/provider 设置，并可迁移现有 provider 配置，
  迁移前会提供备份/回滚。
- 打开 **Settings → Provider**，添加 Anthropic/OpenAI-compatible providers、
  model mappings、proxy 和 extra environment variables。
- 打开 **Settings → MCP**，管理应用本地 MCP servers。LiquidCode 也会读取
  Claude MCP config，并在启动 CLI 时创建每个会话专用的 scratch config。
- 打开 **Settings → CLI**，诊断、安装、更新、修复 Claude Code，或登录
  Claude Code。

## 从本地 release 构建安装

1. 安装带现代 macOS SDK（26/27）的 Xcode。
2. 可选：复制 `.env.example` → `.env`，配置签名/公证身份。
3. 运行：

```bash
./scripts/build-release.sh
# 本地快速冒烟：
# LIQUIDCODE_ARCHS=arm64 ./scripts/build-release.sh
```

4. 安装生成的 `.build-release/LiquidCode-<version>[-unsigned].pkg`。

版本号来自 Xcode 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（写入 app Info.plist）。未配置签名变量时，产物是 ad-hoc 签名 app + unsigned PKG（Gatekeeper 会警告）。生产发布请设 `RELEASE_SIGNING_REQUIRED=1`。


### 校验

```bash
./scripts/verify-release-artifacts.sh
codesign --verify --deep --strict --verbose=2 .build-release/LiquidCode.app
lipo -archs .build-release/LiquidCode.app/Contents/MacOS/LiquidCode
```

### 产物

- `.pkg` — 唯一安装包格式（安装到 `/Applications/LiquidCode.app`）
- `SHA256SUMS` — PKG 的完整性校验文件（`shasum -a 256 -c SHA256SUMS`）
- 中间产物 `.build-release/LiquidCode.app` 仅供检查，CI 不上传

## 发布门禁

```bash
xcodebuild test \
  -project LiquidCode.xcodeproj \
  -scheme LiquidCode \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .xcode-derived
LIQUIDCODE_ARCHS=arm64 RELEASE_UPLOAD_DRY_RUN=1 ./scripts/build-release.sh

./scripts/verify-release-artifacts.sh
```

## 发布产物

- `LiquidCode.app` 来自 Xcode `.xcarchive`（保留在 `.build-release/` 便于检查）。
- `.pkg` 是唯一分发安装包（安装到 `/Applications/LiquidCode.app`）。
- 每个 GitHub Release 都会附带 `SHA256SUMS`，用于校验 PKG 完整性。
- PKG 文件名使用构建出的 app 的 `CFBundleShortVersionString`（来自 Xcode `MARKETING_VERSION`）。


## 版本与 tag

- **唯一来源：** `LiquidCode.xcodeproj` 里的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。
- **查看：** `./scripts/verify-version.sh`
- **打发布 tag：** 自动——每次 push 到 `main` 且 CI 全绿，CI 会打 `v${MARKETING_VERSION}` tag 并发布 unsigned PKG release。手动逃生口：`./scripts/cut-release.sh`。
- **可选覆盖：** 仅上传时才需要 `RELEASE_TAG`；不设则自动用 `v${MARKETING_VERSION}`，且必须与 Xcode 版本一致。

## 更新

- 本地：重新运行 `./scripts/build-release.sh`，安装新 PKG 后重启。
- 上传 dry-run：`RELEASE_UPLOAD_DRY_RUN=1 ./scripts/build-release.sh`（tag 默认从 Xcode 读）。
- 生产上传：`RELEASE_SIGNING_REQUIRED=1`，并配置 Developer ID Application、Installer 与 notary profile，再设 `RELEASE_UPLOAD=1`。


## 卸载

退出 LiquidCode，删除 `/Applications/LiquidCode.app`，并按需移除：

- `~/Library/Application Support/LiquidCode`
- `~/Library/Logs/LiquidCode`
- `~/Library/Preferences/moe.aili.LiquidCode.plist`

## 开发质量门禁

提交前安装 pinned local tooling，并启用仓库跟踪的 Git hook：

```bash
brew bundle install
./scripts/install-git-hooks.sh
```

pre-commit hook 会运行 `./scripts/quality-check.sh`。如果缺少 `swiftlint`、
`swiftformat` 或 `periphery`，它会 fail closed；随后运行 SwiftLint、
SwiftFormat lint mode 和 Periphery。它不会运行 XCTest；完整验证请使用下面的
build/test 命令。

### 构建与测试

```bash
xcodebuild test \
  -project LiquidCode.xcodeproj \
  -scheme LiquidCode \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .xcode-derived
# Development smoke path: uses the same default DerivedData location as Xcode.app.
./scripts/dev-run.sh
# Release/archive path: intentionally isolated under .xcode-derived.
xcodebuild \
  -project LiquidCode.xcodeproj \
  -scheme LiquidCode \
  -configuration Release \
  -derivedDataPath .xcode-derived \
  build
```


## 持续集成

GitHub Actions：

| Workflow | 触发 | 作用 |
|---|---|---|
| `CI` | PR / push main | 质量门禁、单测、未签名 arm64 PKG 构建；main 全绿后自动打 `v${MARKETING_VERSION}` tag 并发布 unsigned PKG release |
| `Release` | `v*` tag / release / 手动 | 签名 + 公证 PKG 发布（配齐 Apple secrets 时） |

本地脚本：

```bash
./scripts/verify-version.sh
./scripts/verify-version.sh --tag vX.Y.Z
./scripts/ci-select-xcode.sh
./scripts/build-release.sh           # archive → 仅 PKG（版本来自 Xcode）
./scripts/verify-release-artifacts.sh
./scripts/cut-release.sh --dry-run   # 读版本预览 tag
./scripts/cut-release.sh             # 本地打 tag 并 push

```

签名模式：要么配齐 App + Installer + notary secrets，要么全部不配走 unsigned；
半配会让 Release workflow 失败。

## 致谢

[TOKENICODE](https://github.com/yiliqi78/TOKENICODE)：Claude Code 精美桌面客户端

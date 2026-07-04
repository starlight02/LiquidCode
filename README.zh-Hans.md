# LiquidCode

LiquidCode 是 Claude Code 桌面客户端的原生 SwiftUI/AppKit macOS 产品化路线。

## 配置

- 首次启动会引导你完成 Claude CLI/provider 设置，并可迁移现有 provider 配置，
  迁移前会提供备份/回滚。
- 打开 **Settings → Provider**，添加 Anthropic/OpenAI-compatible providers、
  model mappings、proxy 和 extra environment variables。
- 打开 **Settings → MCP**，管理应用本地 MCP servers。LiquidCode 也会读取
  Claude MCP config，并在启动 CLI 时创建每个会话专用的 scratch config。
- 打开 **Settings → CLI**，诊断、安装、更新、修复 Claude Code，或登录
  Claude Code。

## 从本地发布构建安装

1. 安装 Xcode 27 或更新版本。
2. 可选：复制 `.env.example` 为 `.env`，并设置 `CODESIGN_IDENTITY` 和
   `NOTARY_KEYCHAIN_PROFILE`，用于 notarized Developer ID release。
3. 运行 `./scripts/build-release.sh`。
4. 打开生成的 `.build-release/LiquidCode-<version>.dmg`，把 `LiquidCode.app`
   拖到 `/Applications`。

如果未设置签名变量，脚本只会创建 ad-hoc signed development DMG。设置
`RELEASE_SIGNING_REQUIRED=1` 可启用 release gates；缺少签名或公证变量时，
脚本会在 build 前失败。

## 发布门禁

```bash
xcodebuild test \
  -project LiquidCode.xcodeproj \
  -scheme LiquidCode \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .xcode-derived
xcodebuild \
  -project LiquidCode.xcodeproj \
  -scheme LiquidCode \
  -configuration Release \
  -derivedDataPath .xcode-derived \
  build
RELEASE_UPLOAD_DRY_RUN=1 RELEASE_TAG=v0.1.0 ./scripts/build-release.sh
codesign --verify --deep --strict --verbose=2 .build-release/LiquidCode.app
hdiutil verify .build-release/*.dmg
lipo -archs .build-release/LiquidCode.app/Contents/MacOS/LiquidCode
python3 -m json.tool .build-release/latest.json >/tmp/liquidcode-latest-json-check.txt
```

## 发布产物

- `LiquidCode.app` 从 Xcode `.xcarchive` product 复制，不由脚本手工拼装。
- `.dmg` 是 macOS 安装器产物。
- `.app.tar.gz` 加 `.sha256` 是最小 updater payload/checksum，直到 signed
  native updater protocol 定稿。
- `latest.json` 从构建出的 app Info.plist 生成，所以 version、build 和
  display name 会与 Xcode 保持一致。

## 更新

- 本地构建：重新运行 `./scripts/build-release.sh`，打开新的 DMG，替换
  `/Applications/LiquidCode.app`，然后重新启动。
- release upload dry-runs：设置
  `RELEASE_UPLOAD_DRY_RUN=1 RELEASE_TAG=v<version>`；脚本会验证完整 upload
  matrix，不会触碰 GitHub。
- 生产 release upload：设置 `RELEASE_SIGNING_REQUIRED=1`、Developer
  ID/notary/updater signing variables 和 `RELEASE_UPLOAD_DRY_RUN=0`；缺少
  signing/notary material 时，脚本会在 build 前失败。
- 生成的 `latest.json` 是 updater manifest contract：`version`、`build`、
  app name、DMG URL、updater tarball、signature 和 checksum 必须在上传前
  通过验证。

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

## 致谢

[TOKENICODE](https://github.com/yiliqi78/TOKENICODE)：Claude Code 精美桌面客户端
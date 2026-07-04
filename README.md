# LiquidCode

LiquidCode is the native SwiftUI/AppKit macOS productization track for a
Claude Code desktop client. TOKENICODE remains the parity reference for
release flow, resource packaging, signing, notarization, and update metadata
until LiquidCode has its own production release history.

## Configure

- First launch guides you through Claude CLI/provider setup and can migrate
  existing TOKENICODE provider configuration with backup/rollback.
- Open **Settings → Provider** to add Anthropic/OpenAI-compatible providers,
  model mappings, proxy, and extra environment variables.
- Open **Settings → MCP** to manage app-local MCP servers. LiquidCode also
  reads Claude MCP config and creates per-session scratch config when launching
  the CLI.
- Open **Settings → CLI** to diagnose, install, update, repair, or log in to
  Claude Code.

## Install from a local release build

1. Install Xcode 27 or newer.
2. Optional: copy `.env.example` to `.env` and set `CODESIGN_IDENTITY` plus
   `NOTARY_KEYCHAIN_PROFILE` for a notarized Developer ID release.
3. Run `./scripts/build-release.sh`.
4. Open the generated `.build-release/LiquidCode-<version>.dmg` and drag
   `LiquidCode.app` to `/Applications`.

Without signing variables the script creates an ad-hoc signed development DMG
only. Set `RELEASE_SIGNING_REQUIRED=1` for release gates; missing signing or
notary variables fail before build.

## Release gates

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

## Release artifacts

- `LiquidCode.app` is copied from the Xcode `.xcarchive` product, not
  handcrafted by the script.
- `.dmg` is the macOS installer artifact.
- `.app.tar.gz` plus `.sha256` is the minimal updater payload/checksum until a
  signed native updater protocol is finalized.
- `latest.json` is generated from the built app Info.plist so version, build,
  and display name match Xcode.

## Update

- For local builds, rerun `./scripts/build-release.sh`, open the new DMG,
  replace `/Applications/LiquidCode.app`, and relaunch.
- For release upload dry-runs, set
  `RELEASE_UPLOAD_DRY_RUN=1 RELEASE_TAG=v<version>`; the script validates the
  complete upload matrix without touching GitHub.
- For production release upload, set `RELEASE_SIGNING_REQUIRED=1`, Developer
  ID/notary/updater signing variables, and `RELEASE_UPLOAD_DRY_RUN=0`; missing
  signing/notary material fails before build.
- The generated `latest.json` is the updater manifest contract: `version`,
  `build`, app name, DMG URL, updater tarball, signature, and checksum must
  validate before upload.

## Uninstall

Quit LiquidCode, delete `/Applications/LiquidCode.app`, and optionally remove:

- `~/Library/Application Support/LiquidCode`
- `~/Library/Logs/LiquidCode`
- `~/Library/Preferences/moe.aili.LiquidCode.plist`

## Development quality gate

Install the pinned local tooling and enable the tracked Git hook before committing:

```bash
brew bundle install
./scripts/install-git-hooks.sh
```

The pre-commit hook runs `./scripts/quality-check.sh`. It fails closed when
`swiftlint`, `swiftformat`, or `periphery` is missing, then runs SwiftLint,
SwiftFormat lint mode, and Periphery. It intentionally does not run XCTest;
use the build/test commands below for full verification.

### Build & test

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

For visual QA, do not mix two Debug bundles with the same
`moe.aili.LiquidCode` bundle id.
`./scripts/dev-run.sh` builds into Xcode.app's normal DerivedData output, kills
stale `LiquidCode.app`/debugserver processes, and opens that exact app bundle.

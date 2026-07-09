#!/usr/bin/env bash
# Post-build verification for .build-release artifacts (used by CI and local smoke).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${1:-$ROOT/.build-release}"
APP_NAME="LiquidCode"
APP="$BUILD_DIR/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"
REQUIRE_NOTARIZED="${REQUIRE_NOTARIZED:-0}"
ARCHS_VALUE="${LIQUIDCODE_ARCHS:-arm64 x86_64}"

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -d "$APP" ]] || fail "Missing app bundle: $APP"
[[ -f "$PLIST" ]] || fail "Missing Info.plist: $PLIST"
command -v codesign >/dev/null || fail "codesign not found"
command -v lipo >/dev/null || fail "lipo not found"
command -v hdiutil >/dev/null || fail "hdiutil not found"
command -v python3 >/dev/null || fail "python3 not found"
[[ -x "$PLISTBUDDY" ]] || fail "PlistBuddy not found"

info "codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

info "lipo architecture check ($ARCHS_VALUE)"
actual_archs="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
for expected_arch in $ARCHS_VALUE; do
  [[ " $actual_archs " == *" $expected_arch "* ]] || fail "Missing arch '$expected_arch' (found: $actual_archs)"
done
echo "    Architectures: $actual_archs"

info "sidecar presence"
[[ -x "$APP/Contents/Resources/cc-agentd.mjs" ]] || fail "Missing executable sidecar: Contents/Resources/cc-agentd.mjs"

version="$($PLISTBUDDY -c 'Print :CFBundleShortVersionString' "$PLIST")"
build="$($PLISTBUDDY -c 'Print :CFBundleVersion' "$PLIST")"
bundle_id="$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$PLIST")"
echo "    Bundle ID: $bundle_id"
echo "    Version:   $version ($build)"
[[ "$bundle_id" == "moe.aili.LiquidCode" ]] || fail "Unexpected bundle id: $bundle_id"

shopt -s nullglob
dmgs=("$BUILD_DIR"/*.dmg)
tarballs=("$BUILD_DIR"/*.app.tar.gz)
sigs=("$BUILD_DIR"/*.app.tar.gz.sig)
shas=("$BUILD_DIR"/*.app.tar.gz.sha256)
latest=("$BUILD_DIR"/latest.json)
shopt -u nullglob

[[ ${#dmgs[@]} -eq 1 ]] || fail "Expected exactly one DMG in $BUILD_DIR (found ${#dmgs[@]})"
[[ ${#tarballs[@]} -eq 1 ]] || fail "Expected exactly one .app.tar.gz in $BUILD_DIR"
[[ ${#sigs[@]} -eq 1 ]] || fail "Expected exactly one .app.tar.gz.sig in $BUILD_DIR"
[[ ${#shas[@]} -eq 1 ]] || fail "Expected exactly one .app.tar.gz.sha256 in $BUILD_DIR"
[[ ${#latest[@]} -eq 1 ]] || fail "Expected latest.json in $BUILD_DIR"

dmg="${dmgs[0]}"
info "hdiutil verify $(basename "$dmg")"
hdiutil verify "$dmg"

info "latest.json contract"
python3 - "$latest" "$version" "$build" "$(basename "$dmg")" "$(basename "${tarballs[0]}")" "$(basename "${sigs[0]}")" "$(awk '{print $1}' "${shas[0]}")" <<'PY'
import json
import sys

path, version, build, dmg, updater, sig_file, checksum = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
platform = data.get("platforms", {}).get("darwin-universal", {})
checks = {
    "version": data.get("version") == version,
    "build": data.get("build") == build,
    "url": platform.get("url") == dmg,
    "updater": platform.get("updater") == updater,
    "updater_signature": platform.get("updater_signature") == sig_file,
    "checksum": platform.get("checksum") == checksum,
    "signature_present": bool(platform.get("signature")),
}
failed = [k for k, ok in checks.items() if not ok]
if failed:
    raise SystemExit("latest.json validation failed: " + ", ".join(failed))
print("    latest.json OK")
PY

if [[ "$REQUIRE_NOTARIZED" == "1" ]]; then
  info "stapler / spctl (notarized release)"
  xcrun stapler validate "$dmg"
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
  info "stapler/spctl skipped (REQUIRE_NOTARIZED!=1)"
fi

info "DMG install smoke"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/liquidcode-dmg.XXXXXX")"
install_dir="$(mktemp -d "${TMPDIR:-/tmp}/liquidcode-install.XXXXXX")"
cleanup() {
  hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  rm -rf "$mount_dir" "$install_dir"
}
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg"
[[ -d "$mount_dir/$APP_NAME.app" ]] || fail "DMG does not contain $APP_NAME.app"
ditto "$mount_dir/$APP_NAME.app" "$install_dir/$APP_NAME.app"
[[ -x "$install_dir/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]] || fail "Installed app binary not executable"
codesign --verify --deep --strict --verbose=2 "$install_dir/$APP_NAME.app"

info "verify-release-artifacts passed"

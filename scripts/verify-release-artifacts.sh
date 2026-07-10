#!/usr/bin/env bash
# Post-build verification for PKG-only release artifacts.
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
command -v pkgutil >/dev/null || fail "pkgutil not found"
command -v shasum >/dev/null || fail "shasum not found"
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
pkgs=("$BUILD_DIR"/*.pkg)
shopt -u nullglob
[[ ${#pkgs[@]} -eq 1 ]] || fail "Expected exactly one PKG in $BUILD_DIR (found ${#pkgs[@]})"
pkg="${pkgs[0]}"

info "pkgutil inspect $(basename "$pkg")"
pkgutil --check-signature "$pkg" || true

CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liquidcode-pkg-check.XXXXXX")"
cleanup() { rm -rf "$CHECK_DIR"; }
trap cleanup EXIT
# pkgutil --expand-full requires the destination path to not already exist.
rmdir "$CHECK_DIR"
pkgutil --expand-full "$pkg" "$CHECK_DIR"
package_app="$CHECK_DIR/$APP_NAME-component.pkg/Payload/Applications/$APP_NAME.app"
[[ -d "$package_app" ]] || fail "PKG payload missing Applications/$APP_NAME.app"
[[ -x "$package_app/Contents/MacOS/$APP_NAME" ]] || fail "Installed app binary not executable"
codesign --verify --deep --strict --verbose=2 "$package_app"

CHECKSUMS="${pkg}.sha256"
info "verify $(basename "$CHECKSUMS")"
[[ -f "$CHECKSUMS" ]] || fail "Missing integrity file: $CHECKSUMS"
[[ -s "$CHECKSUMS" ]] || fail "Empty integrity file: $CHECKSUMS"
# shasum -c expects relative paths as written (basename of the PKG).
(
  cd "$BUILD_DIR"
  shasum -a 256 -c "$(basename "$CHECKSUMS")"
)
# Ensure the listed file is exactly the one PKG we just verified.
listed="$(awk 'NF>=2 {print $NF; exit}' "$CHECKSUMS")"
[[ "$listed" == "$(basename "$pkg")" ]] || fail "$(basename "$CHECKSUMS") lists '$listed' but PKG is '$(basename "$pkg")'"

if [[ "$REQUIRE_NOTARIZED" == "1" ]]; then
  info "stapler validate PKG"
  xcrun stapler validate "$pkg"
  spctl --assess --type execute --verbose "$APP"
else
  info "stapler/spctl skipped (REQUIRE_NOTARIZED!=1)"
fi

info "verify-release-artifacts passed"

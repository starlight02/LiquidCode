#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LiquidCode"
PROJECT="LiquidCode.xcodeproj"
SCHEME="LiquidCode"
CONFIGURATION="Release"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.xcode-derived"
BUILD_DIR="$ROOT/.build-release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
APP="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="$ROOT/Config/LiquidCode.entitlements"
SIDECAR_RELATIVE="Contents/Resources/cc-agentd.mjs"
SIDECAR="$APP/$SIDECAR_RELATIVE"
PLIST="$APP/Contents/Info.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"
ARCHS_VALUE="${LIQUIDCODE_ARCHS:-arm64 x86_64}"
RELEASE_SIGNING_REQUIRED="${RELEASE_SIGNING_REQUIRED:-0}"
RELEASE_HELPERS="$ROOT/scripts/release-helpers.sh"
# shellcheck source=scripts/release-helpers.sh
source "$RELEASE_HELPERS"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
RELEASE_UPLOAD_ENABLED="$(release_upload_enabled_value)"
RELEASE_UPLOAD_DRY_RUN_ENABLED="$(release_upload_dry_run_value)"
RELEASE_CREATE_DRAFT_ENABLED="$(release_create_draft_value)"
RELEASE_TAG_VALUE="$(release_tag_value)"


fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v xcodebuild >/dev/null || fail "xcodebuild not found"
command -v codesign >/dev/null || fail "codesign not found"
command -v hdiutil >/dev/null || fail "hdiutil not found"
command -v xcrun >/dev/null || fail "xcrun not found"
command -v ditto >/dev/null || fail "ditto not found"
command -v tar >/dev/null || fail "tar not found"
command -v shasum >/dev/null || fail "shasum not found"
command -v python3 >/dev/null || fail "python3 not found"
command -v lipo >/dev/null || fail "lipo not found"
command -v spctl >/dev/null || fail "spctl not found"
[[ -x "$PLISTBUDDY" ]] || fail "PlistBuddy not found at $PLISTBUDDY"

if release_truthy "$RELEASE_SIGNING_REQUIRED"; then
  [[ -n "${CODESIGN_IDENTITY:-}" ]] || fail "RELEASE_SIGNING_REQUIRED=1 requires CODESIGN_IDENTITY"
  [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] || fail "RELEASE_SIGNING_REQUIRED=1 requires NOTARY_KEYCHAIN_PROFILE"
  updater_signing_key_present || fail "RELEASE_SIGNING_REQUIRED=1 requires updater signing key env (UPDATER_SIGNING_PRIVATE_KEY/UPDATER_SIGNING_PRIVATE_KEY_PATH or TAURI_SIGNING_PRIVATE_KEY/TAURI_SIGNING_PRIVATE_KEY_PATH)"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  security find-identity -v -p codesigning | grep -F "$CODESIGN_IDENTITY" >/dev/null || fail "CODESIGN_IDENTITY not found in keychain: $CODESIGN_IDENTITY"
fi

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && -z "${CODESIGN_IDENTITY:-}" ]]; then
  fail "NOTARY_KEYCHAIN_PROFILE requires Developer ID signing via CODESIGN_IDENTITY"
fi

if release_truthy "$RELEASE_UPLOAD_ENABLED" && ! release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED" && ! release_truthy "$RELEASE_SIGNING_REQUIRED"; then
  fail "RELEASE_UPLOAD=1 real uploads require RELEASE_SIGNING_REQUIRED=1; use RELEASE_UPLOAD_DRY_RUN=1 for dev/ad-hoc validation"
fi

if release_truthy "$RELEASE_UPLOAD_ENABLED" && ! release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED"; then
  preflight_real_release_upload "$RELEASE_TAG_VALUE"
fi

if release_truthy "$RELEASE_SIGNING_REQUIRED"; then
  info "Release mode: production signed/notarized release (Developer ID + notary + updater signature required)"
else
  info "Release mode: development/ad-hoc build; artifacts are for local smoke/dry-run only and must not be published."
fi
if release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED"; then
  info "Upload mode: GitHub release dry-run"
elif release_truthy "$RELEASE_UPLOAD_ENABLED"; then
  info "Upload mode: real GitHub release upload"
else
  info "Upload mode: disabled"
fi
if release_truthy "$RELEASE_CREATE_DRAFT_ENABLED"; then
  info "Draft release behavior: create/reuse GitHub draft release before uploading assets."
fi

cd "$ROOT"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

info "Archiving $APP_NAME via Xcode project ($PROJECT / $SCHEME / $CONFIGURATION)"
info "Universal strategy: ARCHS=\"$ARCHS_VALUE\" ONLY_ACTIVE_ARCH=NO"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  ARCHS="$ARCHS_VALUE" \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO

[[ -d "$ARCHIVE_APP" ]] || fail "Xcode archive did not produce $ARCHIVE_APP"
ditto "$ARCHIVE_APP" "$APP"
[[ -f "$PLIST" ]] || fail "Archived app is missing Info.plist: $PLIST"
[[ -f "$SIDECAR" ]] || fail "Archived app is missing sidecar from Xcode Resources phase: $SIDECAR_RELATIVE"
chmod +x "$SIDECAR"

DISPLAY_NAME="$($PLISTBUDDY -c 'Print :CFBundleDisplayName' "$PLIST" 2>/dev/null || true)"
[[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$($PLISTBUDDY -c 'Print :CFBundleName' "$PLIST")"
VERSION="$($PLISTBUDDY -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$($PLISTBUDDY -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$PLIST")"
SAFE_DISPLAY_NAME="${DISPLAY_NAME// /-}"
DMG="$BUILD_DIR/${SAFE_DISPLAY_NAME}-${VERSION}.dmg"
UPDATER_TARBALL="$BUILD_DIR/${SAFE_DISPLAY_NAME}-${VERSION}.app.tar.gz"
UPDATER_SHA="$UPDATER_TARBALL.sha256"
UPDATER_SIG="$UPDATER_TARBALL.sig"
LATEST_JSON="$BUILD_DIR/latest.json"

info "Resolved identity/version from Xcode-built Info.plist"
echo "    Display name: $DISPLAY_NAME"
echo "    Bundle ID:    $BUNDLE_ID"
echo "    Version:      $VERSION ($BUILD_NUMBER)"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  info "Signing with Developer ID identity: $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$SIDECAR"
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP"
else
  info "CODESIGN_IDENTITY not set; dev build uses ad-hoc signing and is not a notarized release."
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

info "Gate: codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

info "Gate: lipo architecture check"
ACTUAL_ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
for expected_arch in $ARCHS_VALUE; do
  [[ " $ACTUAL_ARCHS " == *" $expected_arch "* ]] || fail "Missing expected architecture '$expected_arch' in $APP_NAME executable (found: $ACTUAL_ARCHS)"
done
echo "    Architectures: $ACTUAL_ARCHS"

info "Creating DMG: $DMG"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"

info "Creating updater tarball and checksum"
(cd "$BUILD_DIR" && tar -czf "$UPDATER_TARBALL" "$APP_NAME.app")
shasum -a 256 "$UPDATER_TARBALL" > "$UPDATER_SHA"
sign_updater_artifact "$UPDATER_TARBALL" "$UPDATER_SIG" "$RELEASE_SIGNING_REQUIRED"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  info "Gate: xcrun notarytool submit DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  info "Gate: xcrun stapler staple DMG"
  xcrun stapler staple "$DMG"
  info "Gate: xcrun stapler validate DMG"
  xcrun stapler validate "$DMG"
  info "Gate: spctl assess app and DMG"
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  info "Gate: notarization/stapler/spctl skipped for development/ad-hoc build; this is not a production release."
fi

PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SIGNATURE_TEXT="$(signature_text_for_metadata "$UPDATER_SIG")"
info "Generating update manifest: $LATEST_JSON"
python3 - "$LATEST_JSON" "$VERSION" "$BUILD_NUMBER" "$PUB_DATE" "$DISPLAY_NAME" "$(basename "$DMG")" "$(basename "$UPDATER_TARBALL")" "$(basename "$UPDATER_SIG")" "$(awk '{print $1}' "$UPDATER_SHA")" "$SIGNATURE_TEXT" <<'PY'
import json, sys
path, version, build, pub_date, name, dmg, updater, sig_file, checksum, signature = sys.argv[1:]
data = {"version": version, "build": build, "pub_date": pub_date, "name": name, "platforms": {"darwin-universal": {"url": dmg, "updater": updater, "updater_signature": sig_file, "signature": signature, "checksum": checksum}}}
json.dump(data, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY

info "Gate: latest.json manifest validation"
python3 - "$LATEST_JSON" "$VERSION" "$BUILD_NUMBER" "$DISPLAY_NAME" "$(basename "$DMG")" "$(basename "$UPDATER_TARBALL")" "$(basename "$UPDATER_SIG")" "$(awk '{print $1}' "$UPDATER_SHA")" "$SIGNATURE_TEXT" <<'PY'
import json
import sys

path, version, build, name, dmg, updater, sig_file, checksum, signature = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
platform = data.get("platforms", {}).get("darwin-universal", {})
checks = {
    "version": data.get("version") == version,
    "build": data.get("build") == build,
    "name": data.get("name") == name,
    "url": platform.get("url") == dmg,
    "updater": platform.get("updater") == updater,
    "updater_signature": platform.get("updater_signature") == sig_file,
    "checksum": platform.get("checksum") == checksum,
    "signature": platform.get("signature") == signature and signature and "placeholder" not in signature,
}
failed = [key for key, ok in checks.items() if not ok]
if failed:
    raise SystemExit("ERROR: latest.json validation failed: " + ", ".join(failed))
PY

ARTIFACTS=("$DMG" "$UPDATER_TARBALL" "$UPDATER_SIG" "$UPDATER_SHA" "$LATEST_JSON")
ARTIFACT_PURPOSES=(
  "macOS installer DMG"
  "Tauri-compatible updater payload"
  "Updater minisign/Tauri signature"
  "Updater payload SHA-256 checksum"
  "Updater manifest for darwin-universal"
)

info "Release artifact matrix"
printf "    %-40s %-12s %s\n" "Artifact" "Upload" "Purpose"
for artifact_index in "${!ARTIFACTS[@]}"; do
  upload_label="skipped"
  if release_truthy "$RELEASE_UPLOAD_ENABLED" || release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED"; then
    upload_label="yes"
  fi
  printf "    %-40s %-12s %s\n" "$(basename "${ARTIFACTS[$artifact_index]}")" "$upload_label" "${ARTIFACT_PURPOSES[$artifact_index]}"
done

export RELEASE_NAME="${RELEASE_NAME:-$DISPLAY_NAME $RELEASE_TAG_VALUE}"
export RELEASE_NOTES="${RELEASE_NOTES:-Archive-derived macOS release for $DISPLAY_NAME $VERSION. Assets: DMG installer, updater tarball, updater signature, checksum, and latest.json manifest.}"
if release_truthy "$RELEASE_UPLOAD_ENABLED" || release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED"; then
  release_upload_artifacts "$RELEASE_UPLOAD_DRY_RUN_ENABLED" "$RELEASE_TAG_VALUE" "${ARTIFACTS[@]}"
else
  info "RELEASE_UPLOAD/RELEASE_UPLOAD_DRY_RUN not set; upload skipped."
fi

info "Release artifacts"
echo "$APP"
echo "$DMG"
echo "$UPDATER_TARBALL"
echo "$UPDATER_SIG"
echo "$UPDATER_SHA"
echo "$LATEST_JSON"

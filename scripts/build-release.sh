#!/usr/bin/env bash
# Build a signed (or ad-hoc) LiquidCode.app and wrap it as a macOS PKG installer.
# Output:
#   .build-release/LiquidCode.app
#   .build-release/LiquidCode-<ver>[-unsigned].pkg
#   .build-release/SHA256SUMS
set -euo pipefail

APP_NAME="LiquidCode"
BUNDLE_ID="moe.aili.LiquidCode"
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
export COPYFILE_DISABLE=1

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

need() { command -v "$1" >/dev/null || fail "$1 not found"; }
need xcodebuild
need codesign
need ditto
need lipo
need pkgbuild
need productbuild
need python3
need shasum
[[ -x "$PLISTBUDDY" ]] || fail "PlistBuddy not found"

if release_truthy "$RELEASE_SIGNING_REQUIRED"; then
  [[ -n "${CODESIGN_IDENTITY:-}" ]] || fail "RELEASE_SIGNING_REQUIRED=1 requires CODESIGN_IDENTITY"
  [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]] || fail "RELEASE_SIGNING_REQUIRED=1 requires INSTALLER_SIGN_IDENTITY"
  [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] || fail "RELEASE_SIGNING_REQUIRED=1 requires NOTARY_KEYCHAIN_PROFILE"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  security find-identity -v -p codesigning | grep -F "$CODESIGN_IDENTITY" >/dev/null \
    || fail "CODESIGN_IDENTITY not found in keychain: $CODESIGN_IDENTITY"
fi

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && -z "${CODESIGN_IDENTITY:-}" ]]; then
  fail "NOTARY_KEYCHAIN_PROFILE requires Developer ID signing via CODESIGN_IDENTITY"
fi

if release_truthy "$RELEASE_UPLOAD_ENABLED" && ! release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED" && ! release_truthy "$RELEASE_SIGNING_REQUIRED"; then
  fail "RELEASE_UPLOAD=1 real uploads require RELEASE_SIGNING_REQUIRED=1; use RELEASE_UPLOAD_DRY_RUN=1 for ad-hoc validation"
fi

if release_truthy "$RELEASE_UPLOAD_ENABLED" && ! release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED"; then
  preflight_real_release_upload "$RELEASE_TAG_VALUE"
fi

if release_truthy "$RELEASE_SIGNING_REQUIRED"; then
  info "Release mode: signed + notarized PKG"
else
  info "Release mode: ad-hoc / unsigned PKG (local smoke only)"
fi

cd "$ROOT"

if [[ "$RELEASE_TAG_VALUE" =~ ^v[0-9] ]]; then
  info "Verifying MARKETING_VERSION against RELEASE_TAG=$RELEASE_TAG_VALUE"
  "$ROOT/scripts/verify-version.sh" --tag "$RELEASE_TAG_VALUE"
else
  info "Verifying MARKETING_VERSION metadata"
  "$ROOT/scripts/verify-version.sh"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

info "Archiving $APP_NAME ($ARCHS_VALUE)"
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
xattr -cr "$APP" 2>/dev/null || true
find "$APP" \( -name ".DS_Store" -o -name "._*" \) -delete 2>/dev/null || true
[[ -f "$PLIST" ]] || fail "Missing Info.plist: $PLIST"

# Git provenance in Info.plist
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_commit="$(git rev-parse --short=12 HEAD)"
  git_version="$(git describe --tags --always 2>/dev/null || printf '%s' "$git_commit")"
  git_dirty=false
  if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
    git_dirty=true
    git_version="$git_version-dirty"
  fi
else
  git_commit=unknown
  git_version=unknown
  git_dirty=false
fi
set_plist_string() {
  local key="$1" value="$2"
  if "$PLISTBUDDY" -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Set :$key $value" "$PLIST"
  else
    "$PLISTBUDDY" -c "Add :$key string $value" "$PLIST"
  fi
}
set_plist_string "LiquidCodeGitCommit" "$git_commit"
set_plist_string "LiquidCodeGitVersion" "$git_version"
set_plist_string "LiquidCodeGitDirty" "$git_dirty"

[[ -f "$SIDECAR" ]] || fail "Missing sidecar: $SIDECAR_RELATIVE"
chmod +x "$SIDECAR"

VERSION="$($PLISTBUDDY -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$($PLISTBUDDY -c 'Print :CFBundleVersion' "$PLIST")"
info "Version $VERSION ($BUILD_NUMBER) commit $git_commit"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  info "Signing app: $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$SIDECAR"
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP"
else
  info "Ad-hoc codesign (no CODESIGN_IDENTITY)"
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

info "codesign --verify"
codesign --verify --deep --strict --verbose=2 "$APP"

info "Architecture check ($ARCHS_VALUE)"
ACTUAL_ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
for expected_arch in $ARCHS_VALUE; do
  [[ " $ACTUAL_ARCHS " == *" $expected_arch "* ]] || fail "Missing arch '$expected_arch' (found: $ACTUAL_ARCHS)"
done
echo "    $ACTUAL_ARCHS"

# --- PKG packaging (inlined; was package-macos-pkg.sh) ---
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liquidcode-pkg.XXXXXX")"
cleanup_pkg() { rm -rf "$WORK_DIR"; }
trap cleanup_pkg EXIT

RESOURCES_DIR="$WORK_DIR/resources"
SCRIPTS_DIR="$WORK_DIR/scripts"
STAGING_ROOT="$WORK_DIR/root"
STAGED_APP="$STAGING_ROOT/Applications/$APP_NAME.app"
COMPONENT_PLIST="$WORK_DIR/components.plist"
DISTRIBUTION_XML="$WORK_DIR/Distribution.xml"
COMPONENT_PKG="$WORK_DIR/$APP_NAME-component.pkg"

if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  PKG="$BUILD_DIR/${APP_NAME}-${VERSION}.pkg"
else
  PKG="$BUILD_DIR/${APP_NAME}-${VERSION}-unsigned.pkg"
fi

mkdir -p "$RESOURCES_DIR" "$SCRIPTS_DIR" "$STAGING_ROOT/Applications"
ditto "$APP" "$STAGED_APP"
xattr -cr "$STAGED_APP" 2>/dev/null || true
find "$STAGED_APP" \( -name ".DS_Store" -o -name "._*" \) -delete 2>/dev/null || true

if [[ -f "$ROOT/LICENSE" ]]; then
  cp "$ROOT/LICENSE" "$RESOURCES_DIR/LICENSE.txt"
else
  printf 'LiquidCode\nSee repository README for license terms.\n' >"$RESOURCES_DIR/LICENSE.txt"
fi

cat >"$COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key>
    <true/>
    <key>BundleIsRelocatable</key>
    <false/>
    <key>BundleIsVersionChecked</key>
    <false/>
    <key>BundleOverwriteAction</key>
    <string>upgrade</string>
    <key>RootRelativeBundlePath</key>
    <string>Applications/$APP_NAME.app</string>
  </dict>
</array>
</plist>
EOF

cat >"$DISTRIBUTION_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>$APP_NAME $VERSION</title>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <choices-outline>
    <line choice="default"/>
  </choices-outline>
  <choice id="default" title="$APP_NAME">
    <pkg-ref id="$BUNDLE_ID"/>
  </choice>
  <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">$APP_NAME-component.pkg</pkg-ref>
</installer-gui-script>
EOF

cat >"$SCRIPTS_DIR/preinstall" <<'EOF'
#!/bin/sh
set -u
APP_NAME="LiquidCode"
BUNDLE_ID="moe.aili.LiquidCode"
APP_EXEC="/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
MARKER_FILE="/private/tmp/$BUNDLE_ID.was-running"

matching_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v prefix="$1" '
    { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/,"",$0); if (index($0,prefix)==1) print pid }'
}
running_pids() { matching_pids "$APP_EXEC" | /usr/bin/sort -u; }
has_running() { [ -n "$(running_pids)" ]; }
console_user() { /usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true; }
console_uid() {
  u="$1"; [ -n "$u" ] && [ "$u" != "root" ] && [ "$u" != "loginwindow" ] || return 1
  /usr/bin/id -u "$u" 2>/dev/null
}
run_as_user() {
  u="$(console_user)"; uid="$(console_uid "$u")" || return 1
  /bin/launchctl asuser "$uid" "$@"
}
wait_stop() {
  n="$1"; i=0
  while [ "$i" -lt "$n" ]; do
    has_running || return 0
    /bin/sleep 0.2
    i=$((i + 1))
  done
  return 1
}
signal_all() {
  running_pids | while read -r pid; do
    [ -n "$pid" ] || continue
    /bin/kill "-$1" "$pid" 2>/dev/null || true
  done
}

if ! has_running; then
  /bin/rm -f "$MARKER_FILE"
  exit 0
fi
u="$(console_user)"; uid="$(console_uid "$u" 2>/dev/null || true)"
{ printf 'user=%s\n' "$u"; printf 'uid=%s\n' "$uid"; } >"$MARKER_FILE"
if [ -n "$(matching_pids "$APP_EXEC")" ]; then
  echo "Requesting $APP_NAME to quit..."
  run_as_user /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null \
    || /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
fi
wait_stop 60 && exit 0
signal_all TERM
wait_stop 30 && exit 0
signal_all KILL
wait_stop 10 && exit 0
echo "error: unable to stop $APP_NAME before install" >&2
exit 1
EOF

cat >"$SCRIPTS_DIR/postinstall" <<'EOF'
#!/bin/sh
set -u
APP_NAME="LiquidCode"
BUNDLE_ID="moe.aili.LiquidCode"
MARKER_FILE="/private/tmp/$BUNDLE_ID.was-running"
[ -f "$MARKER_FILE" ] || exit 0
uid=""
while IFS='=' read -r key value; do
  case "$key" in uid) uid="$value" ;; esac
done <"$MARKER_FILE"
/bin/rm -f "$MARKER_FILE"
if [ -n "$uid" ]; then
  /bin/launchctl asuser "$uid" /usr/bin/open "/Applications/$APP_NAME.app" >/dev/null 2>&1 \
    || /bin/launchctl asuser "$uid" /usr/bin/open -b "$BUNDLE_ID" >/dev/null 2>&1 || true
else
  /usr/bin/open "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

info "pkgbuild component"
pkgbuild \
  --root "$STAGING_ROOT" \
  --scripts "$SCRIPTS_DIR" \
  --component-plist "$COMPONENT_PLIST" \
  --install-location / \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --ownership recommended \
  "$COMPONENT_PKG" \
  2> >(grep -v '^write: Permission denied$' >&2 || true)

productbuild_args=(
  --distribution "$DISTRIBUTION_XML"
  --resources "$RESOURCES_DIR"
  --package-path "$WORK_DIR"
)
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  info "productbuild --sign $INSTALLER_SIGN_IDENTITY"
  productbuild_args+=(--sign "$INSTALLER_SIGN_IDENTITY")
else
  info "Unsigned productbuild (no INSTALLER_SIGN_IDENTITY)"
fi
rm -f "$PKG"
productbuild "${productbuild_args[@]}" "$PKG"

info "Inspect PKG payload"
CHECK_DIR="$WORK_DIR/check"
rm -rf "$CHECK_DIR"
pkgutil --expand-full "$PKG" "$CHECK_DIR"
COMPONENT_INFO="$CHECK_DIR/$APP_NAME-component.pkg/PackageInfo"
PACKAGE_APP="$CHECK_DIR/$APP_NAME-component.pkg/Payload/Applications/$APP_NAME.app"
[[ -f "$COMPONENT_INFO" ]] || fail "Missing PackageInfo"
grep -q 'install-location="/"' "$COMPONENT_INFO" || fail "Unexpected install-location"
[[ -x "$PACKAGE_APP/Contents/MacOS/$APP_NAME" ]] || fail "PKG payload binary missing"
[[ -x "$CHECK_DIR/$APP_NAME-component.pkg/Scripts/preinstall" ]] || fail "Missing preinstall"
[[ -x "$CHECK_DIR/$APP_NAME-component.pkg/Scripts/postinstall" ]] || fail "Missing postinstall"

if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  pkgutil --check-signature "$PKG" || fail "PKG signature check failed"
fi

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  if [[ -z "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    fail "Notarization requires INSTALLER_SIGN_IDENTITY"
  fi
  info "notarytool submit PKG"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG"
  spctl --assess --type execute --verbose "$APP" || true
else
  info "Notarization skipped"
fi

# SHA256SUMS is the public integrity file for release consumers.
# Format matches GNU coreutils / shasum -c expectations (hash + two spaces + basename).
CHECKSUMS="$BUILD_DIR/SHA256SUMS"
info "Writing $CHECKSUMS"
(
  cd "$BUILD_DIR"
  shasum -a 256 "$(basename "$PKG")" >SHA256SUMS
)
[[ -s "$CHECKSUMS" ]] || fail "Failed to write SHA256SUMS"
info "Checksum:"
cat "$CHECKSUMS"

ARTIFACTS=("$PKG" "$CHECKSUMS")
export RELEASE_NAME="${RELEASE_NAME:-$APP_NAME $RELEASE_TAG_VALUE}"
export RELEASE_NOTES="${RELEASE_NOTES:-macOS PKG installer for $APP_NAME $VERSION.}"
if release_truthy "$RELEASE_UPLOAD_ENABLED" || release_truthy "$RELEASE_UPLOAD_DRY_RUN_ENABLED"; then
  release_upload_artifacts "$RELEASE_UPLOAD_DRY_RUN_ENABLED" "$RELEASE_TAG_VALUE" "${ARTIFACTS[@]}"
else
  info "Upload skipped"
fi

info "Done"
echo "$APP"
echo "$PKG"
echo "$CHECKSUMS"


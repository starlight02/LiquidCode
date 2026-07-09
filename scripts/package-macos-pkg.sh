#!/usr/bin/env bash
# Build a macOS PKG installer from an already-signed LiquidCode.app.
# Usage: package-macos-pkg.sh /path/to/LiquidCode.app [/path/to/output.pkg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export COPYFILE_DISABLE=1

APP_NAME="LiquidCode"
BUNDLE_ID="moe.aili.LiquidCode"
PLISTBUDDY="/usr/libexec/PlistBuddy"

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

APP_SRC="${1:-}"
[[ -n "$APP_SRC" ]] || fail "Usage: $0 /path/to/LiquidCode.app [output.pkg]"
[[ -d "$APP_SRC" ]] || fail "App bundle not found: $APP_SRC"
[[ -f "$APP_SRC/Contents/Info.plist" ]] || fail "Missing Info.plist in $APP_SRC"

VERSION="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")"
BUILD="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$APP_SRC/Contents/Info.plist")"
BUNDLE_FROM_APP="$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$APP_SRC/Contents/Info.plist")"
[[ "$BUNDLE_FROM_APP" == "$BUNDLE_ID" ]] || fail "Unexpected bundle id: $BUNDLE_FROM_APP"

SAFE_NAME="${APP_NAME}"
OUT_DIR="$(cd "$(dirname "${2:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "${2:-}" ]]; then
  FINAL_PKG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
else
  OUT_DIR="${PKG_OUT_DIR:-$ROOT/.build-release}"
  mkdir -p "$OUT_DIR"
  if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    FINAL_PKG="$OUT_DIR/${SAFE_NAME}-${VERSION}.pkg"
  else
    FINAL_PKG="$OUT_DIR/${SAFE_NAME}-${VERSION}-unsigned.pkg"
  fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liquidcode-pkg.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

RESOURCES_DIR="$WORK_DIR/resources"
SCRIPTS_DIR="$WORK_DIR/scripts"
STAGING_ROOT="$WORK_DIR/root"
STAGED_APP="$STAGING_ROOT/Applications/$APP_NAME.app"
COMPONENT_PLIST="$WORK_DIR/components.plist"
DISTRIBUTION_XML="$WORK_DIR/Distribution.xml"
COMPONENT_PKG="$WORK_DIR/$APP_NAME-component.pkg"

mkdir -p "$RESOURCES_DIR" "$SCRIPTS_DIR" "$STAGING_ROOT/Applications"
ditto "$APP_SRC" "$STAGED_APP"
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

cat >"$SCRIPTS_DIR/preinstall" <<EOF
#!/bin/sh
set -u

APP_NAME="$APP_NAME"
BUNDLE_ID="$BUNDLE_ID"
APP_EXEC="/Applications/\$APP_NAME.app/Contents/MacOS/\$APP_NAME"
MARKER_FILE="/private/tmp/\$BUNDLE_ID.was-running"

matching_pids() {
  executable_prefix="\$1"
  /bin/ps -axo pid=,command= | /usr/bin/awk -v prefix="\$executable_prefix" '
    {
      pid = \$1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", \$0)
      if (index(\$0, prefix) == 1) { print pid }
    }
  '
}

running_pids() {
  matching_pids "\$APP_EXEC" | /usr/bin/sort -u
}

has_running_processes() {
  [ -n "\$(running_pids)" ]
}

console_user() {
  /usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true
}

console_uid() {
  user="\$1"
  [ -n "\$user" ] && [ "\$user" != "root" ] && [ "\$user" != "loginwindow" ] || return 1
  /usr/bin/id -u "\$user" 2>/dev/null
}

run_as_console_user() {
  user="\$(console_user)"
  uid="\$(console_uid "\$user")" || return 1
  /bin/launchctl asuser "\$uid" "\$@"
}

request_app_quit() {
  if [ -z "\$(matching_pids "\$APP_EXEC")" ]; then
    return 0
  fi
  echo "Requesting \$APP_NAME to quit before installing..."
  if ! run_as_console_user /usr/bin/osascript -e "tell application id \"\$BUNDLE_ID\" to quit"; then
    /usr/bin/osascript -e "tell application id \"\$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
}

signal_running_processes() {
  signal="\$1"
  running_pids | while read -r pid; do
    [ -n "\$pid" ] || continue
    /bin/kill "-\$signal" "\$pid" 2>/dev/null || true
  done
}

wait_until_stopped() {
  attempts="\$1"
  index=0
  while [ "\$index" -lt "\$attempts" ]; do
    if ! has_running_processes; then
      return 0
    fi
    /bin/sleep 0.2
    index=\$((index + 1))
  done
  return 1
}

if ! has_running_processes; then
  /bin/rm -f "\$MARKER_FILE"
  exit 0
fi

user="\$(console_user)"
uid="\$(console_uid "\$user" 2>/dev/null || true)"
{
  printf 'user=%s\n' "\$user"
  printf 'uid=%s\n' "\$uid"
} > "\$MARKER_FILE"

request_app_quit
if wait_until_stopped 60; then
  echo "\$APP_NAME stopped cleanly."
  exit 0
fi

echo "\$APP_NAME did not quit in time; sending SIGTERM..."
signal_running_processes TERM
if wait_until_stopped 30; then
  exit 0
fi

echo "\$APP_NAME still running; sending SIGKILL..."
signal_running_processes KILL
if wait_until_stopped 10; then
  exit 0
fi

echo "error: unable to stop \$APP_NAME before installation." >&2
exit 1
EOF

cat >"$SCRIPTS_DIR/postinstall" <<EOF
#!/bin/sh
set -u

APP_NAME="$APP_NAME"
BUNDLE_ID="$BUNDLE_ID"
MARKER_FILE="/private/tmp/\$BUNDLE_ID.was-running"

if [ ! -f "\$MARKER_FILE" ]; then
  exit 0
fi

uid=""
while IFS='=' read -r key value; do
  case "\$key" in
    uid) uid="\$value" ;;
  esac
done < "\$MARKER_FILE"
/bin/rm -f "\$MARKER_FILE"

if [ -n "\$uid" ]; then
  /bin/launchctl asuser "\$uid" /usr/bin/open "/Applications/\$APP_NAME.app" >/dev/null 2>&1 \
    || /bin/launchctl asuser "\$uid" /usr/bin/open -b "\$BUNDLE_ID" >/dev/null 2>&1 \
    || true
else
  /usr/bin/open "/Applications/\$APP_NAME.app" >/dev/null 2>&1 || true
fi

exit 0
EOF
chmod 755 "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

info "Building component package (version $VERSION build $BUILD)"
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
  info "Signing installer with: $INSTALLER_SIGN_IDENTITY"
  productbuild_args+=(--sign "$INSTALLER_SIGN_IDENTITY")
else
  info "INSTALLER_SIGN_IDENTITY not set; producing unsigned PKG"
fi

info "Building product package: $FINAL_PKG"
rm -f "$FINAL_PKG"
productbuild "${productbuild_args[@]}" "$FINAL_PKG"

info "Inspecting installer payload"
CHECK_DIR="$WORK_DIR/check"
rm -rf "$CHECK_DIR"
pkgutil --expand-full "$FINAL_PKG" "$CHECK_DIR"
COMPONENT_INFO="$CHECK_DIR/$APP_NAME-component.pkg/PackageInfo"
PACKAGE_APP="$CHECK_DIR/$APP_NAME-component.pkg/Payload/Applications/$APP_NAME.app"
[[ -f "$COMPONENT_INFO" ]] || fail "Missing PackageInfo after expand"
grep -q 'install-location="/"' "$COMPONENT_INFO" || fail "Unexpected install-location in component package"
[[ -d "$PACKAGE_APP" ]] || fail "PKG payload missing Applications/$APP_NAME.app"
[[ -x "$PACKAGE_APP/Contents/MacOS/$APP_NAME" ]] || fail "PKG payload binary not executable"
[[ -x "$CHECK_DIR/$APP_NAME-component.pkg/Scripts/preinstall" ]] || fail "Missing preinstall script"
[[ -x "$CHECK_DIR/$APP_NAME-component.pkg/Scripts/postinstall" ]] || fail "Missing postinstall script"

if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  pkgutil --check-signature "$FINAL_PKG" || fail "PKG signature check failed"
fi

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  info "Notarizing PKG"
  xcrun notarytool submit "$FINAL_PKG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$FINAL_PKG"
  xcrun stapler validate "$FINAL_PKG"
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  info "Skipping PKG notarization (requires INSTALLER_SIGN_IDENTITY)"
fi

info "PKG ready: $FINAL_PKG"
echo "$FINAL_PKG"

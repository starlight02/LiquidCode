#!/usr/bin/env bash
# Select an Xcode that provides a modern macOS SDK (26/27).
# Mirrors the alma-onebot-bridge CI approach so runners with multiple Xcodes
# do not silently fall back to an SDK older than LiquidCode requires.
set -euo pipefail

prefer_sdks="${LIQUIDCODE_REQUIRED_SDK_REGEX:-macosx2[67]}"

candidates=(
  /Applications/Xcode_27*.app
  /Applications/Xcode_26*.app
  /Applications/Xcode-beta.app
  /Applications/Xcode.app
)

selected=""
shopt -s nullglob
while IFS= read -r app; do
  [[ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]] || continue
  if "$app/Contents/Developer/usr/bin/xcodebuild" -showsdks 2>/dev/null | grep -Eq "$prefer_sdks"; then
    selected="$app"
    break
  fi
done < <(printf "%s\n" "${candidates[@]}" | sort -r)
shopt -u nullglob

if [[ -z "$selected" ]]; then
  echo "No installed Xcode provides a matching macOS SDK ($prefer_sdks)." >&2
  xcodebuild -version || true
  xcodebuild -showsdks || true
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  xcode-select -s "$selected/Contents/Developer"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo xcode-select -s "$selected/Contents/Developer"
else
  # Local non-sudo runs: only report the selection; do not fail the script.
  echo "Selected Xcode (not switched; need sudo): $selected"
  echo "DEVELOPER_DIR=$selected/Contents/Developer"
  export DEVELOPER_DIR="$selected/Contents/Developer"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "DEVELOPER_DIR=$selected/Contents/Developer" >>"$GITHUB_ENV"
  fi
  xcodebuild -version
  xcodebuild -showsdks | grep -E "$prefer_sdks" || true
  exit 0
fi

echo "Using Xcode: $selected"
xcodebuild -version
xcodebuild -showsdks | grep -E "$prefer_sdks"

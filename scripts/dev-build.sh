#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/LiquidCode.xcodeproj"
SCHEME="${SCHEME:-LiquidCode}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"

# Development builds intentionally do NOT pass -derivedDataPath by default.
# That keeps CLI builds aligned with Xcode.app's normal Product > Build/Run output.
# Set LIQUIDCODE_DERIVED_DATA_PATH only when you explicitly want an isolated build root.
USE_CUSTOM_DERIVED_DATA=0
if [[ -n "${LIQUIDCODE_DERIVED_DATA_PATH:-}" ]]; then
  USE_CUSTOM_DERIVED_DATA=1
fi

cd "$ROOT"

echo "[dev-build] project=$PROJECT"
echo "[dev-build] scheme=$SCHEME configuration=$CONFIGURATION destination=$DESTINATION"
if [[ "$USE_CUSTOM_DERIVED_DATA" == "0" ]]; then
  echo "[dev-build] derivedData=default-Xcode-location (matches Xcode GUI)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    build

  settings="$(xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null)"
else
  echo "[dev-build] derivedData=$LIQUIDCODE_DERIVED_DATA_PATH"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$LIQUIDCODE_DERIVED_DATA_PATH" \
    build

  settings="$(xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$LIQUIDCODE_DERIVED_DATA_PATH" \
    -showBuildSettings 2>/dev/null)"
fi

built_products_dir="$(printf '%s\n' "$settings" | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / {print $2; exit}')"
app="$built_products_dir/LiquidCode.app"
bin="$app/Contents/MacOS/LiquidCode"

if [[ ! -x "$bin" ]]; then
  echo "[dev-build] ERROR: expected binary missing: $bin" >&2
  exit 1
fi

hash="$(shasum -a 256 "$bin" | awk '{print $1}')"
mtime="$(stat -f '%Sm' "$bin")"

echo "[dev-build] app=$app"
echo "[dev-build] bin=$bin"
echo "[dev-build] bin_mtime=$mtime"
echo "[dev-build] sha256=$hash"

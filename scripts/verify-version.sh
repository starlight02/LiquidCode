#!/usr/bin/env bash
# Verify LiquidCode MARKETING_VERSION / CURRENT_PROJECT_VERSION metadata.
# Optional: --tag vX.Y.Z requires MARKETING_VERSION == X.Y.Z (tag without leading v).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$ROOT/LiquidCode.xcodeproj/project.pbxproj"

fail() { echo "ERROR: $*" >&2; exit 1; }

tag=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--tag vX.Y.Z]"
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -f "$PBXPROJ" ]] || fail "Missing project file: $PBXPROJ"

# Parse Debug/Release app target settings (bundle id moe.aili.LiquidCode only).
# Keys can appear in any order inside a buildSettings block.
eval "$(
  python3 - "$PBXPROJ" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
# Match each buildSettings { ... } block that targets the main app.
blocks = re.findall(r"buildSettings = \{([^}]+)\};", text, flags=re.S)
marketings = []
builds = []
for block in blocks:
    if "PRODUCT_BUNDLE_IDENTIFIER = moe.aili.LiquidCode;" not in block:
        continue
    m = re.search(r"MARKETING_VERSION = ([^;]+);", block)
    b = re.search(r"CURRENT_PROJECT_VERSION = ([^;]+);", block)
    if m:
        marketings.append(m.group(1).strip())
    if b:
        builds.append(b.group(1).strip())

if not marketings or not builds:
    raise SystemExit("parse-failed")

# All app configs must agree.
if len(set(marketings)) != 1:
    raise SystemExit("marketing-mismatch:" + ",".join(marketings))
if len(set(builds)) != 1:
    raise SystemExit("build-mismatch:" + ",".join(builds))

print(f'marketing="{marketings[0]}"')
print(f'build="{builds[0]}"')
PY
)" || fail "Could not parse version metadata from $PBXPROJ"

[[ -n "${marketing:-}" ]] || fail "Could not read MARKETING_VERSION from $PBXPROJ"
[[ -n "${build:-}" ]] || fail "Could not read CURRENT_PROJECT_VERSION from $PBXPROJ"

if ! [[ "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.+-]+)?$ ]]; then
  fail "MARKETING_VERSION is not a semver-like value: $marketing"
fi
if ! [[ "$build" =~ ^[0-9]+$ ]]; then
  fail "CURRENT_PROJECT_VERSION must be an integer build number: $build"
fi

echo "MARKETING_VERSION=$marketing"
echo "CURRENT_PROJECT_VERSION=$build"

if [[ -n "$tag" ]]; then
  expected="${tag#v}"
  [[ "$marketing" == "$expected" ]] || fail "Tag $tag does not match MARKETING_VERSION $marketing (expected $expected)"
  echo "Tag $tag matches MARKETING_VERSION $marketing"
fi

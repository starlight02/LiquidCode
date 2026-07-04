#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"

missing=()
for tool in swiftlint swiftformat periphery; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if (( ${#missing[@]} > 0 )); then
  printf '[quality-check] ERROR: missing required tool(s): %s\n' "${missing[*]}" >&2
  printf '[quality-check] Install pinned Homebrew tools with: brew bundle install\n' >&2
  exit 127
fi

echo "[quality-check] swiftlint"
swiftlint lint --strict --config "$ROOT/.swiftlint.yml"

echo "[quality-check] swiftformat --lint"
swiftformat "$ROOT/LiquidCode" "$ROOT/LiquidCodeTests" --lint --config "$ROOT/.swiftformat"

echo "[quality-check] periphery scan"
periphery scan --config "$ROOT/.periphery.yml"

echo "[quality-check] passed"

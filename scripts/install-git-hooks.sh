#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_PATH="githooks"

cd "$ROOT"

git config core.hooksPath "$HOOKS_PATH"
printf '[install-git-hooks] core.hooksPath=%s\n' "$HOOKS_PATH"
printf '[install-git-hooks] pre-commit gate=%s/pre-commit\n' "$HOOKS_PATH"

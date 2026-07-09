#!/usr/bin/env bash
# Read MARKETING_VERSION from the Xcode project and create/push a vX.Y.Z release tag.
# Local:
#   ./scripts/cut-release.sh              # create + push tag for current MARKETING_VERSION
#   ./scripts/cut-release.sh --dry-run    # print tag only
#   ./scripts/cut-release.sh --local      # create annotated tag, do not push
# CI auto-tags on green main pushes (see .github/workflows/ci.yml `release` job);
# this script is the local/manual escape hatch for cutting the same tag by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

DRY_RUN=0
LOCAL_ONLY=0
FORCE=0
REMOTE="${CUT_RELEASE_REMOTE:-origin}"
BRANCH="${CUT_RELEASE_BRANCH:-main}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --local) LOCAL_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: cut-release.sh [--dry-run] [--local] [--force] [--remote origin] [--branch main]

Reads MARKETING_VERSION from LiquidCode.xcodeproj and creates annotated tag vX.Y.Z.
Pushing the tag triggers .github/workflows/release.yml (on: push tags v*).
EOF
      exit 0
      ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

command -v git >/dev/null || fail "git not found"
[[ -x "$ROOT/scripts/verify-version.sh" ]] || fail "missing scripts/verify-version.sh"

# Capture MARKETING_VERSION line from verify-version.
version_out="$("$ROOT/scripts/verify-version.sh")"
marketing="$(printf '%s\n' "$version_out" | awk -F= '/^MARKETING_VERSION=/{print $2; exit}')"
build="$(printf '%s\n' "$version_out" | awk -F= '/^CURRENT_PROJECT_VERSION=/{print $2; exit}')"
[[ -n "$marketing" ]] || fail "Could not parse MARKETING_VERSION"
[[ -n "$build" ]] || fail "Could not parse CURRENT_PROJECT_VERSION"

TAG="v${marketing}"
info "Project version: $marketing (build $build) → tag $TAG"

if [[ -n "$(git status --porcelain)" && "$FORCE" != "1" ]]; then
  fail "Working tree is dirty. Commit/stash first, or pass --force."
fi

# Prefer mainline branch tip for release tags unless --force.
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "$BRANCH" && "$FORCE" != "1" && "$DRY_RUN" != "1" ]]; then
  fail "Current branch is '$current_branch' (expected '$BRANCH'). Checkout $BRANCH or pass --force."
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  existing="$(git rev-list -n 1 "$TAG")"
  head="$(git rev-parse HEAD)"
  if [[ "$existing" == "$head" ]]; then
    info "Tag $TAG already points at HEAD"
  else
    fail "Tag $TAG already exists at $existing (HEAD is $head). Bump MARKETING_VERSION or delete the tag."
  fi
  TAG_EXISTS=1
else
  TAG_EXISTS=0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN tag=$TAG version=$marketing build=$build exists=$TAG_EXISTS head=$(git rev-parse --short HEAD)"
  exit 0
fi

if [[ "$TAG_EXISTS" != "1" ]]; then
  info "Creating annotated tag $TAG"
  git tag -a "$TAG" -m "Release $TAG"
fi

if [[ "$LOCAL_ONLY" == "1" ]]; then
  info "Local-only mode: tag created, not pushed"
  echo "$TAG"
  exit 0
fi

info "Pushing tag $TAG to $REMOTE"
git push "$REMOTE" "refs/tags/$TAG"

# Optional: when running under GITHUB_TOKEN (which cannot trigger other workflows
# on tag push), explicitly dispatch the Release workflow if requested.
if [[ "${CUT_RELEASE_DISPATCH_WORKFLOW:-0}" == "1" ]]; then
  command -v gh >/dev/null || fail "CUT_RELEASE_DISPATCH_WORKFLOW=1 requires gh"
  info "Dispatching Release workflow for $TAG"
  # workflow_dispatch on release.yml does not pass the tag ref; prefer re-push
  # with a PAT. As a fallback, create a draft release which triggers on: release.
  if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --title "LiquidCode $TAG" --notes "Cut from MARKETING_VERSION $marketing (build $build)." --draft
  fi
fi

info "Done. Tag $TAG pushed; Release workflow should build artifacts."
echo "$TAG"

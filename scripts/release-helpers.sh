#!/usr/bin/env bash
# Shared helpers for PKG release upload + dev signature fixtures (UpdateService tests).
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

release_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

release_helpers_root() {
  local self="${BASH_SOURCE[0]:-$0}"
  cd "$(dirname "$self")/.." && pwd
}


# Source of truth: Xcode MARKETING_VERSION (via verify-version.sh / project.pbxproj).
release_marketing_version() {
  local out marketing
  out="$("$(release_helpers_root)/scripts/verify-version.sh")"
  marketing="$(printf '%s\n' "$out" | awk -F= '/^MARKETING_VERSION=/{print $2; exit}')"
  [[ -n "$marketing" ]] || fail "Could not read MARKETING_VERSION from Xcode project"
  printf '%s' "$marketing"
}

release_upload_enabled_value() { printf '%s' "${RELEASE_UPLOAD:-0}"; }
release_upload_dry_run_value() { printf '%s' "${RELEASE_UPLOAD_DRY_RUN:-0}"; }
release_create_draft_value() { printf '%s' "${RELEASE_CREATE_DRAFT:-0}"; }
release_name_value() { printf '%s' "${RELEASE_NAME:-}"; }
release_notes_value() { printf '%s' "${RELEASE_NOTES:-}"; }

# Tag resolution order:
#   1. explicit RELEASE_TAG (override only)
#   2. GitHub tag ref (v*) when running on a tag push
#   3. v${MARKETING_VERSION} from the Xcode project (default)
release_tag_value() {
  if [[ -n "${RELEASE_TAG:-}" ]]; then
    printf '%s' "$RELEASE_TAG"
  elif [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" =~ ^v[0-9] ]]; then
    printf '%s' "$GITHUB_REF_NAME"
  else
    printf 'v%s' "$(release_marketing_version)"
  fi
}

release_version_from_tag() {
  local tag="$1"
  [[ -n "$tag" ]] || fail "Release artifact matrix validation requires a release tag"
  echo "${tag#v}"
}


validate_release_artifacts() {
  local artifact
  for artifact in "$@"; do
    [[ -f "$artifact" ]] || fail "Release artifact missing: $artifact"
  done
}

# Accept LiquidCode-X.Y.Z.pkg or LiquidCode-X.Y.Z-unsigned.pkg
validate_release_artifact_matrix() {
  local tag="$1"
  shift
  local version
  version="$(release_version_from_tag "$tag")"
  local found=0 base artifact
  for artifact in "$@"; do
    base="$(basename "$artifact")"
    if [[ "$base" == "LiquidCode-$version.pkg" || "$base" == "LiquidCode-$version-unsigned.pkg" ]]; then
      found=1
      break
    fi
  done
  [[ "$found" == "1" ]] || fail "Incomplete release artifact matrix for $tag; missing: LiquidCode-$version.pkg"
}

preflight_real_release_upload() {
  local tag="$1"
  [[ -n "$tag" ]] || fail "RELEASE_UPLOAD=1 requires a release tag (set RELEASE_TAG or use MARKETING_VERSION)"

  command -v gh >/dev/null || fail "RELEASE_UPLOAD=1 requires gh"
  gh auth status >/dev/null || fail "RELEASE_UPLOAD=1 requires authenticated gh (run gh auth login or set GH_TOKEN)"
}

ensure_github_draft_release() {
  local create_draft="$1"
  local tag="$2"
  local release_name="$3"
  local release_notes="$4"
  release_truthy "$create_draft" || return 0
  [[ -n "$tag" ]] || fail "RELEASE_CREATE_DRAFT=1 requires a release tag"


  if gh release view "$tag" >/dev/null 2>&1; then
    info "GitHub release already exists for $tag; uploading assets to existing release"
    return 0
  fi
  info "Creating draft GitHub release $tag"
  gh release create "$tag" \
    --title "${release_name:-LiquidCode $tag}" \
    --notes "${release_notes:-macOS PKG release $tag}" \
    --draft
}

release_upload_artifacts() {
  local dry_run="$1"
  local tag="$2"
  shift 2

  validate_release_artifacts "$@"
  if [[ -n "$tag" ]]; then
    validate_release_artifact_matrix "$tag" "$@"
  fi

  if release_truthy "$dry_run"; then
    if [[ -n "$tag" ]]; then
      info "GitHub release upload dry-run for $tag"
    else
      info "GitHub release upload dry-run (tag unset)"

    fi
    echo "    Would upload artifacts:"
    local artifact
    for artifact in "$@"; do
      echo "    - $(basename "$artifact") ($artifact)"
    done
    return 0
  fi

  preflight_real_release_upload "$tag"
  ensure_github_draft_release "$(release_create_draft_value)" "$tag" "$(release_name_value)" "$(release_notes_value)"
  gh release upload "$tag" "$@" --clobber || fail "gh release upload failed for $tag"
}

# Deterministic dev signature used by UpdateServiceRegressionTests (not packaging).
write_dev_updater_signature() {
  local artifact="$1"
  local sig_path="$2"
  [[ -f "$artifact" ]] || fail "Missing artifact for dev signature: $artifact"
  python3 - "$artifact" "$sig_path" <<'PY'
import base64, hashlib, hmac, pathlib, sys
artifact, sig_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
payload = artifact.read_bytes()
digest = hashlib.sha256(payload).hexdigest()
key = b"LiquidCode dev-only updater signature v1"
mac = base64.b64encode(hmac.new(key, payload, hashlib.sha512).digest()).decode()
body = (
    "dev-only deterministic signature\n"
    f"sha256:{digest}\n"
    f"mac:{mac}\n"
    "trusted comment: dev-only\n"
)
sig_path.write_text(base64.b64encode(body.encode()).decode() + "\n", encoding="utf-8")
print(sig_path)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  subcommand="${1:-}"
  case "$subcommand" in
    dev-signature)
      [[ $# -eq 3 ]] || fail "Usage: $0 dev-signature <artifact> <sig-path>"
      write_dev_updater_signature "$2" "$3"
      ;;
    upload-dry-run)
      [[ $# -ge 3 ]] || fail "Usage: $0 upload-dry-run <tag> <artifact>..."
      tag="$2"; shift 2
      release_upload_artifacts 1 "$tag" "$@"
      ;;
    upload-real)
      [[ $# -ge 3 ]] || fail "Usage: $0 upload-real <tag> <artifact>..."
      tag="$2"; shift 2
      release_upload_artifacts 0 "$tag" "$@"
      ;;
    marketing-version)
      release_marketing_version
      echo
      ;;
    tag)
      release_tag_value
      echo
      ;;
    *)
      fail "Usage: $0 {dev-signature|upload-dry-run|upload-real|marketing-version|tag} ..."
      ;;

  esac
fi

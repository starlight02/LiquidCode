#!/usr/bin/env bash
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

release_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

release_upload_enabled_value() {
  if [[ -n "${RELEASE_UPLOAD+x}" ]]; then
    echo "${RELEASE_UPLOAD}"
  else
    echo "${GITHUB_RELEASE_UPLOAD:-0}"
  fi
}

release_upload_dry_run_value() {
  if [[ -n "${RELEASE_UPLOAD_DRY_RUN+x}" ]]; then
    echo "${RELEASE_UPLOAD_DRY_RUN}"
  else
    echo "${GITHUB_RELEASE_DRY_RUN:-0}"
  fi
}

release_create_draft_value() {
  if [[ -n "${RELEASE_CREATE_DRAFT+x}" ]]; then
    echo "${RELEASE_CREATE_DRAFT}"
  else
    echo "${GITHUB_RELEASE_CREATE_DRAFT:-0}"
  fi
}

release_name_value() {
  local fallback="${1:-}"
  echo "${RELEASE_NAME:-${GITHUB_RELEASE_NAME:-$fallback}}"
}

release_notes_value() {
  local fallback="${1:-Archive-derived LiquidCode macOS release artifacts.}"
  echo "${RELEASE_NOTES:-${GITHUB_RELEASE_NOTES:-$fallback}}"
}

release_tag_value() {
  echo "${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
}

updater_signing_key_present() {
  [[ -n "${UPDATER_SIGNING_PRIVATE_KEY:-}${TAURI_SIGNING_PRIVATE_KEY:-}${UPDATER_SIGNING_PRIVATE_KEY_PATH:-}${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]]
}

prepare_tauri_signing_environment() {
  export TAURI_SIGNING_PRIVATE_KEY="${TAURI_SIGNING_PRIVATE_KEY:-${UPDATER_SIGNING_PRIVATE_KEY:-}}"
  export TAURI_SIGNING_PRIVATE_KEY_PATH="${TAURI_SIGNING_PRIVATE_KEY_PATH:-${UPDATER_SIGNING_PRIVATE_KEY_PATH:-}}"
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-${UPDATER_SIGNING_PRIVATE_KEY_PASSWORD:-}}"

  if [[ -n "$TAURI_SIGNING_PRIVATE_KEY_PATH" && ! -f "$TAURI_SIGNING_PRIVATE_KEY_PATH" ]]; then
    fail "Updater signing key path does not exist: $TAURI_SIGNING_PRIVATE_KEY_PATH"
  fi
}

find_tauri_cli() {
  if [[ -n "${TAURI_CLI:-}" ]]; then
    [[ -x "$TAURI_CLI" ]] || fail "TAURI_CLI is not executable: $TAURI_CLI"
    echo "$TAURI_CLI"
    return 0
  fi
  command -v tauri 2>/dev/null || true
}

write_dev_updater_signature() {
  local artifact="$1"
  local sig_path="$2"
  [[ -f "$artifact" ]] || fail "Cannot sign missing updater artifact: $artifact"
  python3 - "$artifact" "$sig_path" <<'PY'
import base64
import hashlib
import hmac
import os
import sys

artifact, sig_path = sys.argv[1:3]
with open(artifact, "rb") as fh:
    payload = fh.read()

digest = hashlib.sha256(payload).hexdigest()
mac = base64.b64encode(hmac.new(
    b"LiquidCode dev-only updater signature v1",
    payload,
    hashlib.sha512,
).digest()).decode("ascii")
body = "".join([
    "untrusted comment: dev-only deterministic signature from LiquidCode test key\n",
    mac + "\n",
    f"trusted comment: dev-only; file:{os.path.basename(artifact)}; sha256:{digest}\n",
    mac + "\n",
])
with open(sig_path, "w", encoding="utf-8") as fh:
    fh.write(base64.b64encode(body.encode("utf-8")).decode("ascii") + "\n")
PY
}

sign_updater_artifact() {
  local artifact="$1"
  local sig_path="$2"
  local release_signing_required="${3:-0}"
  [[ -f "$artifact" ]] || fail "Cannot sign missing updater artifact: $artifact"

  if updater_signing_key_present; then
    prepare_tauri_signing_environment
    local tauri_bin
    tauri_bin="$(find_tauri_cli)"
    [[ -n "$tauri_bin" ]] || fail "Updater signing key is set, but no tauri CLI was found. Install/provide tauri or set TAURI_CLI to an executable."
    local sign_args=(signer sign)
    local key_value="$TAURI_SIGNING_PRIVATE_KEY"
    if [[ -n "$TAURI_SIGNING_PRIVATE_KEY_PATH" ]]; then
      sign_args+=("-f" "$TAURI_SIGNING_PRIVATE_KEY_PATH")
    elif [[ -n "$key_value" && -f "$key_value" ]]; then
      sign_args+=("-f" "$key_value")
    else
      sign_args+=("-k" "$key_value")
    fi
    if [[ -n "$TAURI_SIGNING_PRIVATE_KEY_PASSWORD" ]]; then
      sign_args+=("-p" "$TAURI_SIGNING_PRIVATE_KEY_PASSWORD")
    fi
    sign_args+=("$artifact")
    rm -f "$sig_path" "$artifact.sig"
    "$tauri_bin" "${sign_args[@]}"
    [[ -s "$artifact.sig" ]] || fail "tauri signer did not create signature: $artifact.sig"
    if [[ "$artifact.sig" != "$sig_path" ]]; then
      mv "$artifact.sig" "$sig_path"
    fi
    info "Created Tauri/minisign updater signature: $sig_path"
  else
    if release_truthy "$release_signing_required"; then
      fail "RELEASE_SIGNING_REQUIRED=1 requires UPDATER_SIGNING_PRIVATE_KEY/UPDATER_SIGNING_PRIVATE_KEY_PATH or TAURI_SIGNING_PRIVATE_KEY/TAURI_SIGNING_PRIVATE_KEY_PATH"
    fi
    write_dev_updater_signature "$artifact" "$sig_path"
    info "Created dev-only deterministic updater signature: $sig_path"
  fi

  [[ -s "$sig_path" ]] || fail "Updater signature is empty: $sig_path"
}

signature_text_for_metadata() {
  local sig_path="$1"
  [[ -s "$sig_path" ]] || fail "Missing updater signature: $sig_path"
  python3 - "$sig_path" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().strip())
PY
}

validate_release_artifacts() {
  local artifact
  for artifact in "$@"; do
    [[ -f "$artifact" ]] || fail "Release artifact missing: $artifact"
  done
}

release_version_from_tag() {
  local tag="$1"
  [[ -n "$tag" ]] || fail "Release artifact matrix validation requires RELEASE_TAG or GITHUB_REF_NAME"
  echo "${tag#v}"
}

validate_release_artifact_matrix() {
  local tag="$1"
  shift
  local version
  version="$(release_version_from_tag "$tag")"
  local required=(
    "LiquidCode-$version.dmg"
    "LiquidCode-$version.app.tar.gz"
    "LiquidCode-$version.app.tar.gz.sig"
    "LiquidCode-$version.app.tar.gz.sha256"
    "latest.json"
  )

  local missing=()
  local expected artifact base found
  for expected in "${required[@]}"; do
    found=0
    for artifact in "$@"; do
      base="$(basename "$artifact")"
      if [[ "$base" == "$expected" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" != "1" ]]; then
      missing+=("$expected")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    fail "Incomplete release artifact matrix for $tag; missing: ${missing[*]}"
  fi
}

preflight_real_release_upload() {
  local tag="$1"
  [[ -n "$tag" ]] || fail "RELEASE_UPLOAD=1 requires RELEASE_TAG or GITHUB_REF_NAME"
  command -v gh >/dev/null || fail "RELEASE_UPLOAD=1 requires gh"
  gh auth status >/dev/null || fail "RELEASE_UPLOAD=1 requires authenticated gh (run gh auth login or set GH_TOKEN)"
}

ensure_github_draft_release() {
  local create_draft="$1"
  local tag="$2"
  local release_name="$3"
  local release_notes="$4"
  release_truthy "$create_draft" || return 0
  [[ -n "$tag" ]] || fail "RELEASE_CREATE_DRAFT=1 requires RELEASE_TAG or GITHUB_REF_NAME"

  if gh release view "$tag" >/dev/null 2>&1; then
    info "GitHub release already exists for $tag; uploading assets to existing release"
    return 0
  fi

  [[ -n "$release_name" ]] || release_name="$tag"
  [[ -n "$release_notes" ]] || release_notes="Archive-derived LiquidCode macOS release artifacts."
  info "Creating GitHub draft release: $tag"
  gh release create "$tag" --draft --title "$release_name" --notes "$release_notes" || fail "gh release create --draft failed for $tag"
}

release_upload_artifacts() {
  local dry_run="$1"
  local tag="$2"
  shift 2

  if ! release_truthy "$dry_run"; then
    preflight_real_release_upload "$tag"
  fi
  validate_release_artifacts "$@"
  validate_release_artifact_matrix "$tag" "$@"

  local create_draft
  create_draft="$(release_create_draft_value)"
  local release_name
  release_name="$(release_name_value "$tag")"
  local release_notes
  release_notes="$(release_notes_value)"

  if release_truthy "$dry_run"; then
    if [[ -n "$tag" ]]; then
      info "GitHub release upload dry-run for $tag"
    else
      info "GitHub release upload dry-run (RELEASE_TAG/GITHUB_REF_NAME unset; no upload will be attempted)"
    fi
    if release_truthy "$create_draft"; then
      echo "    Would create/reuse GitHub draft release: ${release_name:-$tag}"
    fi
    echo "    Would upload artifacts:"
    local artifact
    for artifact in "$@"; do
      echo "    - $(basename "$artifact") ($artifact)"
    done
    return 0
  fi

  : "real upload preflight already passed"
  ensure_github_draft_release "$create_draft" "$tag" "$release_name" "$release_notes"
  gh release upload "$tag" "$@" --clobber || fail "gh release upload failed for $tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command -v python3 >/dev/null || fail "python3 not found"
  subcommand="${1:-}"
  case "$subcommand" in
    dev-signature)
      [[ $# -eq 3 ]] || fail "Usage: $0 dev-signature <artifact> <sig-path>"
      write_dev_updater_signature "$2" "$3"
      ;;
    sign)
      [[ $# -eq 3 ]] || fail "Usage: $0 sign <artifact> <sig-path>"
      sign_updater_artifact "$2" "$3" "${RELEASE_SIGNING_REQUIRED:-0}"
      ;;
    upload-dry-run)
      [[ $# -ge 3 ]] || fail "Usage: $0 upload-dry-run <tag> <artifact>..."
      tag="$2"
      shift 2
      release_upload_artifacts 1 "$tag" "$@"
      ;;
    upload-real)
      [[ $# -ge 3 ]] || fail "Usage: $0 upload-real <tag> <artifact>..."
      tag="$2"
      shift 2
      release_upload_artifacts 0 "$tag" "$@"
      ;;
    *)
      fail "Usage: $0 {dev-signature|sign|upload-dry-run|upload-real} ..."
      ;;
  esac
fi

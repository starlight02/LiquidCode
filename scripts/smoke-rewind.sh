#!/bin/sh
set -eu

WORKDIR="${1:-$(mktemp -d /tmp/liquidcode-rewind.XXXXXX)}"
MODEL_ARG="${CLAUDE_MODEL:+--model $CLAUDE_MODEL}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if ! command -v claude >/dev/null 2>&1; then
  echo "BLOCKED: claude CLI not found on PATH" >&2
  exit 2
fi

printf 'before\n' > rewind-target.txt

echo "Running Claude live edit in $WORKDIR"
# shellcheck disable=SC2086
claude $MODEL_ARG --permission-mode bypassPermissions --print 'Append exactly the line after to rewind-target.txt and make no other changes.'

echo "Diff after edit:"
git init -q
if ! git config user.email >/dev/null 2>&1; then git config user.email liquidcode-smoke@example.invalid; fi
if ! git config user.name >/dev/null 2>&1; then git config user.name 'LiquidCode Smoke'; fi
git add rewind-target.txt
git commit -qm baseline
# shellcheck disable=SC2086
claude $MODEL_ARG --permission-mode bypassPermissions --print 'Append exactly the line checkpoint to rewind-target.txt and make no other changes.'
git diff -- rewind-target.txt

cat <<'NOTE'
Manual rewind step: use the checkpoint UUID emitted by the Claude JSONL session for the second user turn,
then run: claude --resume <session-id> --rewind-files <checkpoint-uuid>
and verify `git diff -- rewind-target.txt` returns to the pre-second-edit state.
NOTE

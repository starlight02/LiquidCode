#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_LOG="${BUILD_LOG:-$ROOT/.artifacts/dev-build.log}"
mkdir -p "$(dirname "$BUILD_LOG")"

"$ROOT/scripts/dev-build.sh" | tee "$BUILD_LOG"
app="$(awk -F'app=' '/^\[dev-build\] app=/{print $2}' "$BUILD_LOG" | tail -1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "[dev-run] ERROR: could not resolve built app from $BUILD_LOG" >&2
  exit 1
fi

kill_stale_liquidcode() {
  python3 - <<'PY'
import os, signal, subprocess, time
rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,args='], text=True).splitlines()
entries = {}
for row in rows:
    parts = row.strip().split(None, 2)
    if len(parts) < 3:
        continue
    pid, ppid, args = int(parts[0]), int(parts[1]), parts[2]
    entries[pid] = (ppid, args)

targets = set()
for pid, (ppid, args) in entries.items():
    if '/LiquidCode.app/Contents/MacOS/LiquidCode' in args:
        targets.add(pid)
        parent = entries.get(ppid)
        if parent and '/debugserver ' in parent[1]:
            targets.add(ppid)

for sig in (signal.SIGTERM, signal.SIGKILL):
    for pid in sorted(targets):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            print(f'[dev-run] WARN: no permission to kill pid={pid}')
    if targets:
        time.sleep(0.35)

if targets:
    print('[dev-run] killed stale LiquidCode/debugserver pids=' + ','.join(map(str, sorted(targets))))
else:
    print('[dev-run] no stale LiquidCode process found')
PY
}

kill_stale_liquidcode

echo "[dev-run] opening exact app=$app"
open -n "$app"
sleep 1.0

echo "[dev-run] running processes:"
ps -axo pid,ppid,stat,args | grep -F '/LiquidCode.app/Contents/MacOS/LiquidCode' | grep -v grep || true

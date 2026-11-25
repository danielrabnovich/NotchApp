#!/bin/bash
# Visual regression check for Home: renders every HomeShots fixture (each card set × music
# large/small/none × both widths) in the running NotchApp and compares it with a saved baseline.
#   scripts/homeshots.sh baseline   save this build's shots as the baseline
#   scripts/homeshots.sh check      shoot again and diff against the baseline (exit 1 on changes)
# Needs a NotchApp running with debugHooks on (defaults write com.notchapp.NotchApp debugHooks -bool YES),
# normally build/NotchApp.app swapped in for the installed copy. Shots live in .build/homeshots.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"
ROOT=".build/homeshots"
TOOLS=".build/tools"
mkdir -p "$ROOT" "$TOOLS"

# The helpers, compiled once and again whenever their source changes.
for tool in debug imagediff; do
  if [ ! -x "$TOOLS/$tool" ] || [ "scripts/$tool.swift" -nt "$TOOLS/$tool" ]; then
    swiftc -O "scripts/$tool.swift" -o "$TOOLS/$tool"
  fi
done

if ! pgrep -qx NotchApp; then echo "✗ NotchApp isn't running"; exit 2; fi
if [ "$(defaults read com.notchapp.NotchApp debugHooks 2>/dev/null)" != "1" ]; then
  echo "✗ Turn on debugHooks first: defaults write com.notchapp.NotchApp debugHooks -bool YES (then relaunch)"; exit 2
fi

shoot() {
  local dir="$PWD/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  "$TOOLS/debug" homeshot "$dir"
  # The sheet is written last, once every shot is done (about a minute).
  for _ in $(seq 1 240); do
    [ -f "$dir/sheet.png" ] && return 0
    sleep 0.5
  done
  echo "✗ No shots after two minutes: is this NotchApp new enough to have homeshot, and is debugHooks on?"
  exit 2
}

case "$MODE" in
  baseline)
    shoot "$ROOT/baseline"
    echo "✓ Baseline saved: $(ls "$ROOT/baseline" | grep -c png) images in $ROOT/baseline"
    ;;
  check)
    if [ ! -d "$ROOT/baseline" ]; then echo "✗ No baseline yet: run scripts/homeshots.sh baseline on a good build"; exit 2; fi
    shoot "$ROOT/current"
    "$TOOLS/imagediff" "$ROOT/baseline" "$ROOT/current" "$ROOT/diffs" "${THRESHOLD:-0.3}"
    ;;
  *)
    echo "usage: scripts/homeshots.sh baseline|check"; exit 64 ;;
esac

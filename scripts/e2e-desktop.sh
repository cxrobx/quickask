#!/bin/bash
# Desktop control end to end: QuickAsk's MCP server drives a fixture app (and, with --chrome,
# an isolated Chrome profile) in the background while your front app stays in front.
# Needs Accessibility and Screen Recording for the terminal running it. Takes ~30 s.
#
#   bash scripts/e2e-desktop.sh [path/to/QuickAsk.app] [--chrome] [--shots <dir>]
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_dir/dist/QuickAsk.app"
[[ $# -gt 0 && "$1" == *.app ]] && { app="$1"; shift; }
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/quickask-e2e-desktop.XXXXXX")"
chrome_pid=""
cleanup() { [[ -n "$chrome_pid" ]] && kill "$chrome_pid" 2>/dev/null; rm -rf "$build_dir"; }
trap cleanup EXIT
if [[ -d /Library/Developer/CommandLineTools/SDKs ]]; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi
sdk="$(/usr/bin/xcrun --show-sdk-path)"
[[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]] && sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
swiftc() { "$(/usr/bin/xcrun --find swiftc)" -swift-version 5 -O -parse-as-library -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$build_dir/cache" "$@"; }
swiftc "$project_dir/Tests/E2E/ControlFixture.swift" -o "$build_dir/control-fixture"
swiftc "$project_dir/Tests/E2E/DesktopControlE2E.swift" -o "$build_dir/desktop-control-e2e"
args=()
front_pid="$(lsappinfo info -only pid "$(lsappinfo front)" | grep -o '[0-9]\+')"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrome)
      if [[ -d "/Applications/Google Chrome.app" ]]; then
        # A separate instance on a throwaway profile, opened behind your windows: your own
        # Chrome windows are untouched.
        open -g -n -a "Google Chrome" --args --user-data-dir="$build_dir/chrome" --no-first-run --no-default-browser-check \
          --window-size=700,500 --window-position=80,80 "file://$project_dir/Tests/E2E/control-page.html"
        sleep 4
        chrome_pid="$(pgrep -f -- "--user-data-dir=$build_dir/chrome" | head -1)"
        # Chrome brings itself forward once it has loaded; give the front back.
        osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $front_pid) to true" >/dev/null
        args+=(--chrome "$chrome_pid")
      else
        echo "SKIP Chrome checks: Google Chrome is not installed"
      fi ;;
    --shots) args+=(--shots "$2"); shift ;;
  esac
  shift
done
"$build_dir/desktop-control-e2e" "$app" "$build_dir/control-fixture" ${args[@]+"${args[@]}"}

#!/bin/bash
# Builds the surfaces end-to-end harness (Tests/E2E/SurfacesE2E.swift) and runs one question.
#   bash scripts/e2e-surfaces.sh onyx "what does this page say about the launch?"
#   COPILOT_PORT=17891 MEETING_COPILOT_SOCKET=... bash scripts/e2e-surfaces.sh any "how am I doing?"
# Real apps, real routing and a real provider: it costs a request each run.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
binary="$project_dir/build/e2e-surfaces"
mkdir -p "$project_dir/build"
if [[ ! -x "$binary" || -n "$(find "$project_dir/Sources" "$project_dir/Tests/E2E" -newer "$binary" -name '*.swift' | head -1)" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs ]]; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi
  sdk="$(/usr/bin/xcrun --show-sdk-path)"
  [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]] && sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
  sources=()
  for file in "$project_dir"/Sources/QuickAsk/*.swift; do [[ "$(basename "$file")" == Main.swift ]] || sources+=("$file"); done
  "$(/usr/bin/xcrun --find swiftc)" -swift-version 5 -parse-as-library -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$project_dir/build/e2e-cache" "${sources[@]}" "$project_dir/Tests/E2E/SurfacesE2E.swift" -o "$binary"
fi
exec "$binary" "$@"

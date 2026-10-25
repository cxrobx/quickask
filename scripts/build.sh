#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$project_dir/dist/QuickAsk.app}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/quickask-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

# Prefer the standalone Command Line Tools when available. No Xcode license changes.
if [[ -d /Library/Developer/CommandLineTools/SDKs ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
sdk="${QUICKASK_SDK:-$(/usr/bin/xcrun --show-sdk-path)}"
if [[ -z "${QUICKASK_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]]; then
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources" "$build_dir/cache"
cd "$project_dir"
"$swift_compiler" -swift-version 5 -O -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" \
  -Xclang-linker -isysroot -Xclang-linker "$sdk" \
  -module-cache-path "${QUICKASK_MODULE_CACHE:-$build_dir/cache}" \
  "$project_dir"/Sources/QuickAsk/*.swift \
  -o "$destination/Contents/MacOS/QuickAsk"
cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>QuickAsk</string>
<key>CFBundleDisplayName</key><string>QuickAsk</string>
<key>CFBundleIdentifier</key><string>local.quickask.desktop</string>
<key>CFBundleExecutable</key><string>QuickAsk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>QuickAsk.icns</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.quickask.chat</string><key>CFBundleURLSchemes</key><array><string>quickask</string></array></dict></array>
<key>NSAppleEventsUsageDescription</key><string>QuickAsk runs the scripts you ask for in the app you selected, such as exporting an image.</string>
<key>NSMicrophoneUsageDescription</key><string>QuickAsk listens while voice mode is on, so you can talk to the chat.</string>
<key>NSLocalNetworkUsageDescription</key><string>QuickAsk's agents reach services on your home network, such as MCP servers on the NAS.</string>
</dict></plist>
PLIST
"$swift_compiler" -sdk "$sdk" -module-cache-path "$build_dir/cache" "$project_dir/scripts/Icon.swift" -o "$build_dir/icon"
"$build_dir/icon" "$build_dir/QuickAsk.iconset" "$destination/Contents/Resources/QuickAsk.icns"
# A stable identity keeps Accessibility and Screen Recording grants across
# rebuilds; macOS ties an ad-hoc signature's grants to that one binary's hash.
identity="${QUICKASK_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -F'"' '/Apple Development: /{print $2; exit}')}"
if [[ -n "$identity" ]] && /usr/bin/codesign --force --sign "$identity" "$destination" 2>/dev/null; then
  printf 'Signed with %s\n' "$identity"
else
  /usr/bin/codesign --force --sign - "$destination"
  printf 'Signed ad hoc (permission grants reset on each rebuild)\n'
fi
/usr/bin/codesign --verify --strict "$destination"
printf 'Built %s\n' "$destination"

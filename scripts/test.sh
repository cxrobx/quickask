#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/quickask-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
if [[ -d /Library/Developer/CommandLineTools/SDKs ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
sdk="${QUICKASK_SDK:-$(/usr/bin/xcrun --show-sdk-path)}"
if [[ -z "${QUICKASK_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]]; then
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi
"$(/usr/bin/xcrun --find swiftc)" -swift-version 5 -sdk "$sdk" \
  -module-cache-path "${QUICKASK_MODULE_CACHE:-$build_dir/cache}" \
  "$project_dir/Sources/QuickAsk/Provider.swift" "$project_dir/Sources/QuickAsk/Activity.swift" "$project_dir/Sources/QuickAsk/WorkLogView.swift" "$project_dir/Sources/QuickAsk/WarmPool.swift" "$project_dir/Sources/QuickAsk/DesktopTools.swift" "$project_dir/Sources/QuickAsk/AppScripting.swift" \
  "$project_dir/Sources/QuickAsk/BackgroundInput.swift" "$project_dir/Sources/QuickAsk/AgentCursor.swift" "$project_dir/Sources/QuickAsk/AppKnowledge.swift" \
  "$project_dir/Sources/QuickAsk/ContextRouting.swift" "$project_dir/Sources/QuickAsk/ScreenContext.swift" \
  "$project_dir/Sources/QuickAsk/ContextGateway.swift" "$project_dir/Sources/QuickAsk/AppModel.swift" \
  "$project_dir/Sources/QuickAsk/TaskDelegation.swift" "$project_dir/Sources/QuickAsk/HerdrHandoff.swift" "$project_dir/Sources/QuickAsk/Attachments.swift" "$project_dir/Sources/QuickAsk/RoutingSignals.swift" "$project_dir/Sources/QuickAsk/PopupView.swift" "$project_dir/Sources/QuickAsk/MarkdownView.swift" "$project_dir/Sources/QuickAsk/MediaViews.swift" "$project_dir/Sources/QuickAsk/ScreenLook.swift" \
  "$project_dir/Sources/QuickAsk/GlassAppearance.swift" "$project_dir/Sources/QuickAsk/ResizeHandle.swift" "$project_dir/Sources/QuickAsk/CoachCard.swift" "$project_dir/Sources/QuickAsk/OnyxPage.swift" "$project_dir/Sources/QuickAsk/MeetingCopilot.swift" "$project_dir/Sources/QuickAsk/Voice.swift" \
  "$project_dir/Sources/QuickAsk/ChatRecovery.swift" "$project_dir/Tests/ChatRecoveryTests.swift" \
  "$project_dir/Sources/QuickAsk/FollowUpCheck.swift" "$project_dir/Sources/QuickAsk/StatusFeed.swift" "$project_dir/Tests/StatusFeedTests.swift" \
  "$project_dir/Sources/QuickAsk/ChatHistory.swift" "$project_dir/Tests/ChatHistoryTests.swift" \
  "$project_dir/Tests/StreamingTests.swift" "$project_dir/Tests/VoiceTests.swift" \
  "$project_dir/Tests/PopupLayoutTests.swift" "$project_dir/Tests/HarnessEval.swift" "$project_dir/Tests/ProviderTests.swift" -o "$build_dir/tests"
"$build_dir/tests"

#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p build/evaluation-cache
/usr/bin/xcrun swiftc -swift-version 5 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -module-cache-path build/evaluation-cache \
  Sources/QuickAsk/Provider.swift Sources/QuickAsk/Activity.swift Sources/QuickAsk/WorkLogView.swift Sources/QuickAsk/MediaViews.swift Sources/QuickAsk/ScreenLook.swift Sources/QuickAsk/WarmPool.swift Sources/QuickAsk/DesktopTools.swift Sources/QuickAsk/AppScripting.swift Sources/QuickAsk/BackgroundInput.swift Sources/QuickAsk/AgentCursor.swift Sources/QuickAsk/AppKnowledge.swift \
  Sources/QuickAsk/ContextRouting.swift Sources/QuickAsk/ScreenContext.swift \
  Sources/QuickAsk/ContextGateway.swift Sources/QuickAsk/RoutingSignals.swift Sources/QuickAsk/Attachments.swift Sources/QuickAsk/OnyxPage.swift Sources/QuickAsk/MeetingCopilot.swift Sources/QuickAsk/CoachCard.swift Sources/QuickAsk/Voice.swift Sources/QuickAsk/FollowUpCheck.swift Sources/QuickAsk/StatusFeed.swift \
  Sources/QuickAsk/AppModel.swift Sources/QuickAsk/TaskDelegation.swift Sources/QuickAsk/HerdrHandoff.swift Sources/QuickAsk/PopupView.swift Sources/QuickAsk/MarkdownView.swift \
  Sources/QuickAsk/GlassAppearance.swift Sources/QuickAsk/ResizeHandle.swift Sources/QuickAsk/ChatRecovery.swift Sources/QuickAsk/ChatHistory.swift \
  Tests/HarnessEval.swift Tests/ReplyEval.swift -o build/reply-evaluation
build/reply-evaluation

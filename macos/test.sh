#!/bin/bash
set -euo pipefail
TEST_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-dictation-checks.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationProcessingProgress.swift" \
  "$TEST_SOURCE_DIR/tests/DictationProcessingProgressTests.swift" -o "$TEST_BUILD_DIR/progress-checks"
"$TEST_BUILD_DIR/progress-checks"
swiftc -swift-version 5 "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/tests/DictationStoreTests.swift" -o "$TEST_BUILD_DIR/store-checks"
"$TEST_BUILD_DIR/store-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" \
  "$TEST_SOURCE_DIR/DictationLearningToast.swift" "$TEST_SOURCE_DIR/tests/DictationUITests.swift" -o "$TEST_BUILD_DIR/ui-checks"
"$TEST_BUILD_DIR/ui-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" \
  "$TEST_SOURCE_DIR/tests/DictationWaveformTests.swift" -o "$TEST_BUILD_DIR/waveform-checks"
"$TEST_BUILD_DIR/waveform-checks" "$TEST_BUILD_DIR/frames"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" \
  "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/tests/DictationInsightsTests.swift" \
  -o "$TEST_BUILD_DIR/insights-checks"
"$TEST_BUILD_DIR/insights-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" \
  "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/tests/DictationHistoryLayoutTests.swift" \
  -o "$TEST_BUILD_DIR/history-layout-checks"
"$TEST_BUILD_DIR/history-layout-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" \
  "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" \
  "$TEST_SOURCE_DIR/tests/PromptStudioTests.swift" -o "$TEST_BUILD_DIR/prompt-studio-checks"
"$TEST_BUILD_DIR/prompt-studio-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" \
  "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/CleanupPromptClient.swift" \
  "$TEST_SOURCE_DIR/tests/CleanupPromptClientTests.swift" -o "$TEST_BUILD_DIR/prompt-client-checks"
"$TEST_BUILD_DIR/prompt-client-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/tests/PromptProvenanceTests.swift" -o "$TEST_BUILD_DIR/prompt-provenance-checks"
"$TEST_BUILD_DIR/prompt-provenance-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" \
  "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" \
  "$TEST_SOURCE_DIR/tests/PromptIntegrationTests.swift" -o "$TEST_BUILD_DIR/prompt-integration-checks"
"$TEST_BUILD_DIR/prompt-integration-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/DictationInsights.swift" \
  "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" \
  "$TEST_SOURCE_DIR/tests/HeatmapHoverTests.swift" -o "$TEST_BUILD_DIR/heatmap-hover-checks"
"$TEST_BUILD_DIR/heatmap-hover-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/DictationMotion.swift" \
  "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" \
  "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/tests/ShortcutFeedbackTests.swift" \
  -o "$TEST_BUILD_DIR/shortcut-feedback-checks"
"$TEST_BUILD_DIR/shortcut-feedback-checks"

swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" \
  "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" \
  "$TEST_SOURCE_DIR/tests/DictationMotionTests.swift" -o "$TEST_BUILD_DIR/motion-checks"
"$TEST_BUILD_DIR/motion-checks" "$TEST_BUILD_DIR/motion-frames"

# Temporary fake executable verifies the native setup/pipe/cancellation chain.
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" "$TEST_SOURCE_DIR/DictationMotion.swift" \
  "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" \
  "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/DictationSetup.swift" \
  "$TEST_SOURCE_DIR/tests/DictationSetupTests.swift" -o "$TEST_BUILD_DIR/setup-checks"
"$TEST_BUILD_DIR/setup-checks"

# Continuous PCM conversion, HTTP lifecycle, and independent stacked HUDs.
swiftc -swift-version 5 -parse-as-library -D STREAMING_AUDIO_TESTS -framework AVFoundation \
  "$TEST_SOURCE_DIR/StreamingAudioCapture.swift" "$TEST_SOURCE_DIR/tests/StreamingAudioCaptureTests.swift" \
  -o "$TEST_BUILD_DIR/streaming-audio-checks"
"$TEST_BUILD_DIR/streaming-audio-checks"
swiftc -swift-version 5 -parse-as-library \
  "$TEST_SOURCE_DIR/StreamingDictationClient.swift" "$TEST_SOURCE_DIR/tests/StreamingDictationClientTests.swift" \
  -o "$TEST_BUILD_DIR/streaming-client-checks"
"$TEST_BUILD_DIR/streaming-client-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" \
  "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" \
  "$TEST_SOURCE_DIR/PromptStudio.swift" "$TEST_SOURCE_DIR/tests/DictationHUDStackTests.swift" \
  -o "$TEST_BUILD_DIR/hud-stack-checks"
"$TEST_BUILD_DIR/hud-stack-checks" "$TEST_BUILD_DIR/hud-stack-frames"

# Alternate outputs persist under the original history and never count as new dictation.
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/tests/HistoryRevisionTests.swift" -o "$TEST_BUILD_DIR/history-revision-checks"
"$TEST_BUILD_DIR/history-revision-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/HistoryReprocessClient.swift" "$TEST_SOURCE_DIR/tests/HistoryReprocessClientTests.swift" \
  -o "$TEST_BUILD_DIR/history-reprocess-client-checks"
"$TEST_BUILD_DIR/history-reprocess-client-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/DictationMotion.swift" "$TEST_SOURCE_DIR/DictationViews.swift" "$TEST_SOURCE_DIR/HistoryReprocessing.swift" \
  "$TEST_SOURCE_DIR/DictationInsights.swift" "$TEST_SOURCE_DIR/ShortcutRecorder.swift" "$TEST_SOURCE_DIR/PromptStudio.swift" \
  "$TEST_SOURCE_DIR/tests/HistoryReprocessingTests.swift" -o "$TEST_BUILD_DIR/history-reprocessing-ui-checks"
"$TEST_BUILD_DIR/history-reprocessing-ui-checks" "$TEST_BUILD_DIR/history-reprocessing-frames"

# Local correction learning never changes the original transcript or global text.
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationStore.swift" \
  "$TEST_SOURCE_DIR/tests/DictationLearningStoreTests.swift" -o "$TEST_BUILD_DIR/learning-store-checks"
"$TEST_BUILD_DIR/learning-store-checks"
swiftc -swift-version 5 -parse-as-library "$TEST_SOURCE_DIR/DictationCorrectionObserver.swift" \
  "$TEST_SOURCE_DIR/tests/DictationCorrectionObserverTests.swift" -o "$TEST_BUILD_DIR/correction-observer-checks"
"$TEST_BUILD_DIR/correction-observer-checks"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-word-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(Sources/Keyboop/{WordCompletionIndex,NextWordIndex,LayoutData,ExtraWords,PredictiveLocalModel,WordCompletionRequest,PredictionReferenceIndex,PersonalPredictionStore,PredictionDecision}.swift)
swiftc -O -swift-version 5 -module-cache-path "$test_dir/modules" \
  "${sources[@]}" Tests/WordCompletion/main.swift -o "$test_dir/tests"
KEYBOOP_DATA_DIR="$PWD/Sources/Keyboop/Resources" "$test_dir/tests"

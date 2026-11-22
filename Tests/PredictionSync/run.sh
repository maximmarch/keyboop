#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
    Sources/Keyboop/{PredictionSyncLedger,PredictionSync,PersonalPredictionStore,PredictionReferenceIndex,WordCompletionIndex}.swift \
    Tests/PredictionSync/main.swift -o "$scratch/tests"
"$scratch/tests" "$scratch"

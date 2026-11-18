#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-personal-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(Sources/Keyboop/{WordCompletionIndex,PredictionReferenceIndex,PersonalPredictionStore}.swift)
swiftc -O -swift-version 5 -module-cache-path "$test_dir/modules" \
  "${sources[@]}" Tests/PersonalPrediction/main.swift -o "$test_dir/tests"
"$test_dir/tests"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-spelling-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(Sources/Keyboop/{WordCompletionIndex,NextWordIndex,PredictionReferenceIndex,PersonalPredictionStore,PredictionDecision,SystemWordRecognizer,SymmetricDeleteIndex}.swift)
swiftc -O -swift-version 5 -module-cache-path "$test_dir/modules" \
  "${sources[@]}" Tests/Spelling/main.swift -o "$test_dir/tests"
"$test_dir/tests"

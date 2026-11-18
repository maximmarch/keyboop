#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/keyboop-runtime-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -module-cache-path "$test_dir/cache" \
  Sources/Keyboop/PredictionRuntime.swift Tests/PredictionRuntime/main.swift -o "$test_dir/tests"
"$test_dir/tests"

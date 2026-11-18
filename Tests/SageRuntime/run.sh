#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SAGE_TEST_BUILD="$(mktemp -d)"
trap 'rm -rf "$SAGE_TEST_BUILD"' EXIT
swiftc -O -module-cache-path "$SAGE_TEST_BUILD/cache" \
  Sources/Keyboop/SageRuntime.swift Tests/SageRuntime/main.swift -o "$SAGE_TEST_BUILD/run"
"$SAGE_TEST_BUILD/run"

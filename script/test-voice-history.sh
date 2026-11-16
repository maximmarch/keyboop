#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
swiftc -module-cache-path "$temporary/modules" \
  Sources/Keyboop/ClipboardHistoryCore.swift Sources/Keyboop/VoiceHistoryArchive.swift \
  Tests/VoiceHistory/main.swift -o "$temporary/test"
"$temporary/test"

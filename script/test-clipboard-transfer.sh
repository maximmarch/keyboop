#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$temporary/modules}" Sources/Keyboop/ClipboardHistoryCore.swift \
  Sources/Keyboop/ClipboardTransfer.swift Sources/Keyboop/ClipboardHistoryExport.swift \
  Tests/Migration/main.swift -o "$temporary/test"
"$temporary/test" "$@"

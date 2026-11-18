#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 /path/to/arm64/Keyboop.app" >&2; exit 2; }
checker="$(dirname "$0")/check-app-bundle.sh"
"$checker" "$1"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
candidate="$scratch/Keyboop.app"
negative() {
  local label=$1 expected=$2 output
  shift 2
  rm -rf "$candidate"
  ditto "$bundle" "$candidate"
  "$@"
  if output="$("$checker" "$candidate" 2>&1)"; then
    echo "FAIL: checker accepted $label" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || { echo "$output" >&2; exit 1; }
  echo "PASS: rejected $label"
}
bundle=$1
break_signature() { printf 'tampered\n' >> "$candidate/Contents/Resources/models-catalog.json"; }
negative 'missing executable' 'missing Keyboop executable' rm "$candidate/Contents/MacOS/Keyboop"
negative 'missing Native Host' 'missing Native Host' rm "$candidate/Contents/Helpers/KeyboopNativeHost"
negative 'incorrect executable name' 'incorrect CFBundleExecutable' /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Other' "$candidate/Contents/Info.plist"
wrong_architecture() {
  printf 'int main(void) { return 0; }\n' | xcrun clang -arch x86_64 -x c - -o "$candidate/Contents/MacOS/Keyboop"
}
negative 'incorrect architecture' 'unexpected architecture' wrong_architecture
negative 'missing resource' 'missing resource: trigrams_ru.json' rm "$candidate/Contents/Resources/trigrams_ru.json"
negative 'damaged seal' 'resource' break_signature

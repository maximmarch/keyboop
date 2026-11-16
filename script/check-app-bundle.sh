#!/bin/bash
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { echo "Usage: $0 /path/to/Keyboop.app [arm64|universal]" >&2; exit 2; }
app=$1
architecture=${2:-arm64}
fail() { echo "FAIL: $*" >&2; exit 1; }
require() { [[ -s "$1" ]] || fail "missing resource: ${1##*/}"; }
plist="$app/Contents/Info.plist"
main="$app/Contents/MacOS/Keyboop"
host="$app/Contents/Helpers/KeyboopNativeHost"
resources="$app/Contents/Resources"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
[[ -d "$app" && "$app" == *.app ]] || fail "expected an app bundle"
[[ -f "$main" && -x "$main" ]] || fail "missing Keyboop executable"
[[ -f "$host" && -x "$host" ]] || fail "missing Native Host"
plutil -lint "$plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[[ "$(read_key CFBundleExecutable)" == Keyboop ]] || fail "incorrect CFBundleExecutable"
case "$(read_key CFBundleIdentifier)" in
  ru.keyboop.app|ru.keyboop.app.dev) ;;
  *) fail "incorrect bundle identifier" ;;
esac
case "$architecture" in
  arm64) expected=arm64 ;;
  universal) expected="arm64 x86_64" ;;
  *) fail "invalid architecture expectation" ;;
esac
for binary in "$main" "$host" "$sparkle"; do
  require "$binary"
  actual="$(lipo -archs "$binary" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
  if [[ "$binary" == "$sparkle" ]]; then
    [[ " $actual " == *" arm64 "* ]] || fail "unsupported Sparkle architecture: $actual"
    if [[ "$architecture" == universal ]]; then
      [[ " $actual " == *" x86_64 "* ]] || fail "missing Intel Sparkle slice"
    fi
  else
    [[ "$actual" == "$expected" ]] || fail "unexpected architecture: $actual"
  fi
done
[[ "$(read_key LSMinimumSystemVersion)" == 13.0 &&
   "$(read_key LSMinimumSystemVersionByArchitecture:arm64)" == 14.0 &&
   "$(read_key LSMinimumSystemVersionByArchitecture:x86_64)" == 13.0 ]] ||
  fail "incorrect deployment targets"
[[ "$(read_key LSUIElement)" == true ]] || fail "LSUIElement must be enabled"
for key in CFBundleShortVersionString CFBundleVersion NSMicrophoneUsageDescription NSAudioCaptureUsageDescription SUPublicEDKey; do
  [[ -n "$(read_key "$key")" ]] || fail "missing metadata: $key"
done
for resource in AppIcon.icns models-catalog.json trigrams_en.json trigrams_ru.json typo_rules.json words_en.json words_ru.json Extensions/chrome/manifest.json; do
  require "$resources/$resource"
done
otool -L "$main" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle'
otool -L "$host"
codesign --verify --strict "$host"
codesign --verify --deep --strict --verbose=2 "$app"
echo "PASS: $(read_key CFBundleIdentifier) $(read_key CFBundleShortVersionString) ($(read_key CFBundleVersion)), $expected"

#!/bin/bash
# Build the SAGE helper against a pinned native ONNX Runtime archive. Python is not
# needed to build or run this helper. Only the runtime dylib and its notices ship.
set -euo pipefail
app="$1"
sign_id="$2"
shift 2

project="$(cd "$(dirname "$0")/.." && pwd)"
version=1.22.1
artifact="onnxruntime-osx-universal2-$version"
# Microsoft ONNX Runtime (source commit 89746dc19a0a1ae59ebf4b16df9acab8f99f3925),
# packaged for macOS by the Sherpa-ONNX maintainer.
revision=6a33383b71f539762c6afb12c4c891973cd5711c
expected=0cb654cef13f9e046e9e481365c789859f1b09d350c4ca51242f17fff3d7d112
cache_dir="${KEYBOOP_SAGE_CACHE:-$project/vendor/onnxruntime}"
archive="$cache_dir/$artifact.zip"
destination="$app/Contents/Helpers/sage"
notices="$app/Contents/Resources/Licenses/onnxruntime"
library="libonnxruntime.$version.dylib"

mkdir -p "$cache_dir"
work="$(mktemp -d "$cache_dir/.sage.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT

verify() {
    local digest
    digest="$(shasum -a 256 "$1" | cut -d ' ' -f 1)"
    if [ "$digest" != "$expected" ]; then
        echo "ONNX Runtime: unexpected SHA-256 for $1" >&2
        exit 1
    fi
}

if [ ! -f "$archive" ]; then
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
        "https://huggingface.co/csukuangfj/onnxruntime-libs/resolve/$revision/$version/$artifact.zip?download=true" \
        -o "$work/archive.zip"
    verify "$work/archive.zip"
    mv -f "$work/archive.zip" "$archive"
fi
verify "$archive"

mkdir -p "$destination" "$notices"
unzip -p "$archive" "$artifact/include/onnxruntime_c_api.h" > "$work/onnxruntime_c_api.h"
unzip -p "$archive" "$artifact/lib/$library" > "$work/$library"
unzip -p "$archive" "$artifact/LICENSE" > "$notices/LICENSE"
unzip -p "$archive" "$artifact/ThirdPartyNotices.txt" > "$notices/ThirdPartyNotices.txt"

arches=(-arch arm64)
if [ "${KEYBOOP_UNIVERSAL:-0}" = 1 ]; then
    arches+=(-arch x86_64)
    cp "$work/$library" "$destination/$library"
else
    lipo -thin arm64 "$work/$library" -output "$destination/$library"
fi
chmod 755 "$destination/$library"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 "${arches[@]}" \
    -I "$work" "$project/Sources/KeyboopSage/main.cpp" "$destination/$library" \
    -Wl,-rpath,@loader_path -o "$destination/KeyboopSage"
codesign -fs "$sign_id" "$@" "$destination/$library"
codesign -fs "$sign_id" "$@" "$destination/KeyboopSage"
codesign --verify --strict "$destination/$library"
codesign --verify --strict "$destination/KeyboopSage"

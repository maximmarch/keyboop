#!/bin/bash
# Install a private llama.cpp helper in a newly staged Keyboop bundle.
set -euo pipefail
app="$1"
sign_id="$2"
shift 2
sign_options=("$@")
tag=b11490
cache_dir="${KEYBOOP_LLAMA_CACHE:-$PWD/vendor/llama.cpp/$tag}"
runtime="$app/Contents/Helpers/llama"
notices="$app/Contents/Resources/Licenses/llama.cpp"
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-llama.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$app/Contents/Helpers" "$notices"
mkdir "$runtime"

check_digest() {
  local source="$1" expected="$2" actual
  actual="$(shasum -a 256 "$source" | cut -d ' ' -f 1)"
  if [ "$actual" != "$expected" ]; then
    echo "llama.cpp: unexpected SHA-256 for $source" >&2
    return 1
  fi
}

install_release() {
  local arch="$1" dest="$2" digest="$3"
  local archive="llama-$tag-bin-macos-$arch.tar.gz"
  local unpack="$work/$arch" source artifact
  mkdir -p "$cache_dir" "$unpack" "$dest"

  if [ ! -f "$cache_dir/$archive" ]; then
    curl -fLsS --retry 2 --connect-timeout 10 \
      "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$archive" -o "$work/$archive"
    check_digest "$work/$archive" "$digest"
    # Only publish complete verified archives; concurrent builds can reuse either copy.
    local pending
    pending="$(mktemp "$cache_dir/.llama.XXXXXXXX")"
    cp "$work/$archive" "$pending"
    mv -f "$pending" "$cache_dir/$archive"
  fi
  check_digest "$cache_dir/$archive" "$digest"
  tar -xzf "$cache_dir/$archive" -C "$unpack"
  source="$unpack/llama-$tag"
  install -m 755 "$source/llama-server" "$dest/llama-server"
  test -f "$source/LICENSE"

  # Preserve versioned symlinks and all CPU / Metal runtime plugins built for this architecture.
  for artifact in "$source"/*.dylib "$source"/*.so "$source"/*.metallib "$source"/*.metal; do
    [ -e "$artifact" ] || continue
    cp -Pp "$artifact" "$dest/"
  done
  for artifact in "$source"/LICENSE* "$source"/NOTICE*; do
    [ -f "$artifact" ] || continue
    install -m 644 "$artifact" "$notices/"
  done
}

if [ "${KEYBOOP_LLAMA_OLLAMA_DEV:-0}" = 1 ]; then
  # An offline source for an arm64 development build. This pinned executable has a
  # self-contained Metal slice. Other Ollama components and their backends are not used.
  if [ "${KEYBOOP_RELEASE:-0}" = 1 ] || [ "${KEYBOOP_UNIVERSAL:-0}" = 1 ]; then
    echo "KEYBOOP_LLAMA_OLLAMA_DEV supports only arm64 development builds." >&2
    exit 2
  fi
  source="/Applications/Ollama.app/Contents/Resources"
  check_digest "$source/llama-server" "3806b140070f86d9fb4ab6eb90bebeda995bcba313a17590d34d3332d406e951"
  lipo -thin arm64 "$source/llama-server" -output "$runtime/llama-server"
  for name in LLAMA_CPP_LICENSE LLAMA_CPP_VENDORS_LICENSE CPP_HTTPLIB_LICENSE DLPACK_LICENSE \
              FMT_LICENSE JSON_LICENSE.MIT METAL_CPP_LICENSE.txt PICOJSON_LICENSE XGRAMMAR_LICENSE XGRAMMAR_NOTICE; do
    install -m 644 "$source/$name" "$notices/$name"
  done
else
  install_release arm64 "$runtime" 71b13bd1dff54f33a6ad9b74e1283a81fe3c2f41ddb4bb4905b53591e6179c63
  if [ "${KEYBOOP_UNIVERSAL:-0}" = 1 ]; then
    install_release x64 "$runtime/x86_64" 1f1af395162c9745e01939c92e1e44378aa420134ca181ae56560fe658a5719a
  fi
fi

# Sign real files, not their symlink aliases. Sign each server after its libraries.
while IFS= read -r -d '' binary; do
  codesign -fs "$sign_id" "${sign_options[@]}" "$binary"
done < <(find "$runtime" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
while IFS= read -r -d '' binary; do
  codesign -fs "$sign_id" "${sign_options[@]}" "$binary"
  codesign --verify --strict "$binary"
done < <(find "$runtime" -type f -name llama-server -print0)

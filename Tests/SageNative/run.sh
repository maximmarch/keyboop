#!/bin/bash
# Optional second argument points to the two verified SAGE ONNX files.
set -euo pipefail
helper="$1"
models="${2:-}"
"$helper" --version

for input in "" "50357 invalid" "50357 -1" "50357 50364"; do
    if printf '%s\n' "$input" | "$helper" /dev/null /dev/null >/dev/null 2>&1; then
        echo "SAGE helper accepted an invalid token request" >&2
        exit 1
    fi
done

if [ -n "$models" ]; then
    # «Я хачю узнать как это работает» → «Я хочу узнать, как это работает.»
    corrected="$(printf '50357 1358 2012 283 306 4897 428 481 4452\n' |
        "$helper" "$models/encoder_model.onnx" "$models/decoder_model.onnx")"
    [ "$corrected" = "1358 3027 4897 16 428 481 4452 18 2" ]
    echo "SAGE native inference corrected spelling and punctuation"
fi

echo "SAGE native token protocol passed"

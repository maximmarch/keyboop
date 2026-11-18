#!/usr/bin/env python3
"""Build offline Keyboop resources from the pinned dictionaries in THIRD_PARTY.md."""
import argparse
from collections import Counter, defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import re

CHECKSUMS = {
    "en_50k.txt": "5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458",
    "ru_50k.txt": "6095f507cc167488ec66ada5a85ac50433503a08ad24a07c6eabdf54352c4e7f",
    "en_bigrams.txt.gz": "35a0e3b862cea849ae4a0140e3057953e96bd7376921dab5f4890f4e96392064",
    "en_trigrams.txt.gz": "c74991ac133f6601421d9214e905da493d485e8154001c6d6f66eea23ab3e779",
    "ru_bigrams.txt.gz": "26cfff5b08433c9d647e57902d3d7426790f99fab3e2d5628d367688a7e22b23",
    "ru_trigrams.txt.gz": "a6d20070518364d6d5e1a3da2bcd9d1ce76ff0890ed2293bd29e9be5457bd344",
}


def predictions(path, alphabet, context_size):
    rows = defaultdict(Counter)
    with gzip.open(path, "rt", encoding="utf-8") as source:
        for line in source:
            *context, word, count = line.split()
            if len(context) == context_size and all(map(alphabet.fullmatch, context)):
                rows[" ".join(context)][word] += int(count)
    result = {}
    for context, successors in rows.items():
        top = successors.most_common(2)
        word, count = top[0]
        runner_up = top[1][1] if len(top) == 2 else 0
        total = sum(successors.values())
        # Shares refer to the published top n-grams, not to all corpus occurrences.
        minimum, share, lead = (25, 0.25, 0.05) if context_size == 1 else (12, 0.15, 0.015)
        if (count >= minimum and count >= total * share and count - runner_up >= total * lead
                and alphabet.fullmatch(word) and len(word) >= 2 and word != context.split()[-1]):
            result[context] = word
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    for name, digest in CHECKSUMS.items():
        if hashlib.sha256((args.source_dir / name).read_bytes()).hexdigest() != digest:
            parser.error(f"Unexpected source version: {name}")
    frequencies = {}
    next_words = {"one": {}, "two": {}}
    for lang, pattern in [("ru", "[а-яё]+"), ("en", "[a-z]+")]:
        alphabet = re.compile(pattern)
        with (args.source_dir / f"{lang}_50k.txt").open(encoding="utf-8") as source:
            for line in source:
                word, count = line.split()
                if alphabet.fullmatch(word):
                    frequencies[word] = int(count)
        for size, key, gram in [(1, "one", "bi"), (2, "two", "tri")]:
            path = args.source_dir / f"{lang}_{gram}grams.txt.gz"
            next_words[key].update(predictions(path, alphabet, size))
    phrases = json.loads(Path(__file__).with_name("next-word-phrases.json").read_text(encoding="utf-8"))
    for key in next_words:
        next_words[key].update(phrases[key])
    for name, data in [("word_frequencies", frequencies), ("next_words", next_words)]:
        path = args.output_dir / f"{name}.json"
        path.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=1) + "\n", encoding="utf-8")
    print(f"{len(frequencies)} word frequencies, {len(next_words['one'])} one-word contexts, "
          f"{len(next_words['two'])} two-word contexts.")


if __name__ == "__main__":
    main()

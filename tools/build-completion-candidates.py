#!/usr/bin/env python3
"""Build experimental completion dictionaries for the Swift evaluation tool."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re

import msgpack
from pymorphy3 import MorphAnalyzer


RESOURCES = Path(__file__).resolve().parents[1] / "Sources/Keyboop/Resources"
LANGUAGES = {"en": re.compile(r"[a-z]+"), "ru": re.compile(r"[а-яё]+")}
WORDFREQ_BLOBS = {
    "en": "b0a745f017d7504fca9dd4e5a6681f0682c561a7",
    "ru": "9ee4fe29a82ab5f3de6415a43a80a358e34c9290",
}
EXCLUDED_TAGS = {"Abbr", "Name", "Surn", "Patr", "Geox", "Orgn", "Trad", "Erro", "Arch"}


def wordfreq_counts(path, language):
    data = path.read_bytes()
    header = f"blob {len(data)}\0".encode("ascii")
    if hashlib.sha1(header + data).hexdigest() != WORDFREQ_BLOBS[language]:
        raise ValueError(f"{path.name} does not match the pinned wordfreq blob")
    header, *buckets = msgpack.unpackb(gzip.decompress(data), raw=False)
    if header != {"format": "cB", "version": 1}:
        raise ValueError(f"Unsupported wordfreq format in {path}")
    return {
        word: round(10 ** (9 - centibel / 100))
        for centibel, bucket in enumerate(buckets)
        for word in bucket
        if LANGUAGES[language].fullmatch(word)
    }


def is_standard_form(morphology, word):
    if not morphology.word_is_known(word, strict=True):
        return False
    return any(
        reading.is_known and EXCLUDED_TAGS.isdisjoint(reading.tag.grammemes)
        for reading in morphology.parse(word)
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wordfreq", type=Path, help="directory with the pinned small_en and small_ru files")
    parser.add_argument("output", type=Path, help="directory for the two evaluation JSON files")
    args = parser.parse_args()

    morphology = MorphAnalyzer(lang="ru")
    if morphology.dictionary.meta.get("source_revision") != "417150":
        raise ValueError("Expected OpenCorpora source revision 417150 (pymorphy3-dicts-ru 2.4.417150.4580142)")
    legacy = json.loads((RESOURCES / "word_frequencies.json").read_text(encoding="utf-8"))
    base_ru = set(json.loads((RESOURCES / "words_ru.json").read_text(encoding="utf-8")))

    frequencies = {}
    for language, pattern in LANGUAGES.items():
        counts = {word: count for word, count in legacy.items() if pattern.fullmatch(word)}
        total = sum(counts.values())
        frequencies.update({word: max(1, round(count * 1e9 / total)) for word, count in counts.items()})
        frequencies.update(wordfreq_counts(args.wordfreq / f"small_{language}.msgpack.gz", language))

    # A three-letter prefix plus a two-letter ending is the shortest ranked completion.
    added = sorted(
        word for word in frequencies.keys() - base_ru
        if len(word) >= 5 and LANGUAGES["ru"].fullmatch(word) and is_standard_form(morphology, word)
    )
    args.output.mkdir(parents=True, exist_ok=True)
    for name, words in (("wordfreq", []), ("wordfreq-opencorpora", added)):
        path = args.output / f"{name}.json"
        with path.open("w", encoding="utf-8") as handle:
            json.dump({"words": words, "frequencies": frequencies}, handle,
                      ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        print(f"{path}: {len(frequencies)} frequency entries, {len(words)} supplemental word forms")


if __name__ == "__main__":
    main()

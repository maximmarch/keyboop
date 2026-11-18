#!/usr/bin/env python3
"""Build reproducible dictionaries for Keyboop's completion evaluation."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import unicodedata


RESOURCES = Path(__file__).resolve().parents[1] / "Sources/Keyboop/Resources"
LANGUAGES = {"en": re.compile(r"[a-z]+"), "ru": re.compile(r"[а-яё]+")}
WORDFREQ_BLOBS = {
    "en": "b0a745f017d7504fca9dd4e5a6681f0682c561a7",
    "ru": "9ee4fe29a82ab5f3de6415a43a80a358e34c9290",
}
SYMSPELL = {
    "ru": ("ru-100k.txt", "2028262759546fdc346386369a59541d0464f48634c3103ff3f36d01518efcc6"),
    "en": ("frequency_dictionary_en_82_765.txt", "c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b"),
}
LEEDS = ("50000-russian-words-cyrillic-only.txt", "57fe4356417987c1d0221f32e20b5afeaf45fb7b6c318a9f8f55fb119b81c05f")
EXCLUDED_TAGS = {"Abbr", "Name", "Surn", "Patr", "Geox", "Orgn", "Trad", "Erro", "Arch"}


def checked_text(directory, source):
    filename, digest = source
    data = (directory / filename).read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"{filename} does not match the pinned source")
    return data.decode("utf-8-sig")


def scale_counts(counts):
    total = sum(counts.values())
    return {word: max(1, round(count * 1e9 / total)) for word, count in counts.items()}


def wordfreq_counts(path, language):
    import msgpack

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


def wordfreq_variants(directory, legacy, base_ru):
    from pymorphy3 import MorphAnalyzer

    morphology = MorphAnalyzer(lang="ru")
    if morphology.dictionary.meta.get("source_revision") != "417150":
        raise ValueError("Expected OpenCorpora source revision 417150 (pymorphy3-dicts-ru 2.4.417150.4580142)")
    counts = {
        language: legacy[language] | wordfreq_counts(directory / f"small_{language}.msgpack.gz", language)
        for language in LANGUAGES
    }
    # A three-letter prefix plus a two-letter ending is the shortest ranked completion.
    added = sorted(word for word in counts["ru"].keys() - base_ru
                   if len(word) >= 5 and is_standard_form(morphology, word))
    combined = counts["en"] | counts["ru"]
    yield "wordfreq", {"words": [], "frequencies": combined}
    yield "wordfreq-opencorpora", {"words": added, "frequencies": combined}
    yield "wordfreq-opencorpora-ru", {"language": "ru", "words": added, "frequencies": counts["ru"]}
    yield "wordfreq-en", {"language": "en", "words": [], "frequencies": counts["en"]}


def symspell_variants(directory, legacy):
    for language, source in SYMSPELL.items():
        counts = {}
        for line in checked_text(directory, source).splitlines():
            columns = line.split()
            if not columns:
                continue
            raw_word, raw_count = columns
            word = unicodedata.normalize("NFC", raw_word.lower())
            count = int(raw_count)
            if count > 0 and LANGUAGES[language].fullmatch(word):
                counts[word] = max(counts.get(word, 0), count)
        yield f"symspell-{language}", {
            "language": language, "words": sorted(word for word in counts if len(word) >= 5),
            "frequencies": legacy[language] | scale_counts(counts),
        }


def leeds_variants(directory):
    ranks = {}
    for rank, line in enumerate(checked_text(directory, LEEDS).splitlines(), start=1):
        word = unicodedata.normalize("NFC", line.strip().lower())
        if LANGUAGES["ru"].fullmatch(word):
            ranks.setdefault(word, rank)
    words = sorted(word for word in ranks if len(word) >= 5)
    yield "leeds-words", {"language": "ru", "words": words}
    yield "leeds-ranks", {"language": "ru", "words": words, "ranks": ranks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="directory with the pinned source files")
    parser.add_argument("output", type=Path, help="directory for generated evaluation JSON")
    parser.add_argument("--sources", nargs="+", choices=["wordfreq", "symspell", "leeds"], default=["wordfreq"])
    args = parser.parse_args()

    raw_counts = json.loads((RESOURCES / "word_frequencies.json").read_text(encoding="utf-8"))
    legacy = {
        language: scale_counts({word: count for word, count in raw_counts.items() if pattern.fullmatch(word)})
        for language, pattern in LANGUAGES.items()
    }
    base_ru = set(json.loads((RESOURCES / "words_ru.json").read_text(encoding="utf-8")))
    variants = {
        "wordfreq": wordfreq_variants(args.input, legacy, base_ru),
        "symspell": symspell_variants(args.input, legacy),
        "leeds": leeds_variants(args.input),
    }
    args.output.mkdir(parents=True, exist_ok=True)
    for source in dict.fromkeys(args.sources):
        for name, candidate in variants[source]:
            path = args.output / f"{name}.json"
            with path.open("w", encoding="utf-8") as handle:
                json.dump(candidate, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            print(f"{path}: {len(candidate['words'])} word forms, "
                  f"{len(candidate.get('frequencies', candidate.get('ranks', {})))} weights")


if __name__ == "__main__":
    main()

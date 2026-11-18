#!/usr/bin/env python3
"""Generate Keyboop's next-word table from local Tatoeba CC0 exports."""

import argparse
import bz2
from collections import Counter, defaultdict
from pathlib import Path
import json
import re
import unicodedata


def learn(path, language, words, tables):
    reader = bz2.open if path.suffix == ".bz2" else open
    with reader(path, "rt", encoding="utf-8") as source:
        for line in source:
            columns = line.rstrip("\n").split("\t")
            if len(columns) < 3 or columns[1] != language:
                continue
            text = unicodedata.normalize("NFC", columns[2].lower())
            context = []
            for match in re.finditer(r"\S+|[\r\n]", text):
                token = match.group()
                word = token.lstrip("(«“„[\"‘'")
                if word != token:
                    context.clear()
                stripped = word.rstrip(",.!?;:)]»”\"’")
                if not words.fullmatch(stripped):
                    context.clear()
                    continue
                for index, counts in enumerate(tables, start=1):
                    if len(context) >= index:
                        counts[" ".join(context[-index:])][stripped] += 1
                context.append(stripped)
                del context[:-2]
                if stripped != word:
                    context.clear()


def select(counts, minimum, share, margin):
    selected = {}
    for context, successors in counts.items():
        top = successors.most_common(2)
        word, count = top[0]
        runner_up = top[1][1] if len(top) > 1 else 0
        total = sum(successors.values())
        if (len(word) >= 2 and word != context.split()[-1] and count >= minimum
                and count / total >= share and (count - runner_up) / total >= margin):
            selected[context] = word
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ru", type=Path, required=True, help="rus_sentences_CC0.tsv[.bz2]")
    parser.add_argument("--en", type=Path, required=True, help="eng_sentences_CC0.tsv[.bz2]")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tables = [defaultdict(Counter), defaultdict(Counter)]
    learn(args.ru, "rus", re.compile(r"[а-яё]+"), tables)
    learn(args.en, "eng", re.compile(r"[a-z]+"), tables)
    result = {
        "one": select(tables[0], minimum=12, share=0.70, margin=0.30),
        "two": select(tables[1], minimum=8, share=0.55, margin=0.15),
    }
    if not any(result.values()):
        parser.error("No transitions passed the thresholds. Check the input exports.")
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"One-word contexts: {len(result['one'])}. Two-word contexts: {len(result['two'])}.")


if __name__ == "__main__":
    main()

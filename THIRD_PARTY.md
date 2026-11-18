# Third-party notices

Keyboop распространяется под лицензией MIT ([LICENSE](LICENSE)). Ниже — внешние
компоненты и данные, которые входят в сборку или скачиваются приложением по
явному действию пользователя.

---

## 1. Sparkle — инфраструктура обновлений

Фреймворк <https://sparkle-project.org>, лицензия MIT. Лежит в бандле:
`Keyboop.app/Contents/Frameworks/Sparkle.framework`, бинарный артефакт —
`vendor/sparkle`.

```
Copyright (c) 2006-2013 Andy Matuschak
Copyright (c) 2009-2013 Elgato Systems GmbH
Copyright (c) 2011-2014 Kornel Lesiński
… (полный текст: vendor/sparkle/LICENSE)
```

В форке апстримный `SUFeedURL` по умолчанию не задан (`build-app.sh` включает
его только при явной передаче `KEYBOOP_FEED_URL` в релизном режиме).

## 2. transcribe.cpp — движок распознавания речи

<https://github.com/handy-computer/transcribe.cpp>, лицензия MIT, исходники —
`vendor/transcribe.cpp`. Линкуется статически (`libtranscribe.a`).

```
MIT License
Copyright (c) 2026 The transcribe.cpp authors
… (полный текст: vendor/transcribe.cpp/LICENSE)
```

В составе `transcribe.cpp` статически используются компоненты под MIT:
- **ggml** (тензорный бэкенд, CPU / Metal GPU) — `vendor/transcribe.cpp/ggml/LICENSE`
  (`Copyright (c) 2023-2026 The ggml authors`).
- **Silero VAD** (сегментация речи в `src/transcribe-vad.cpp`) —
  `vendor/transcribe.cpp/src/third_party/silero_vad/LICENSE`
  (`Copyright (c) 2020-present Silero Team`).
- **miniz** (сжатие/распаковка для эвристик Whisper) —
  `vendor/transcribe.cpp/src/third_party/miniz/LICENSE`.

Подробности см. в `vendor/transcribe.cpp/THIRD-PARTY-LICENSES.md`.

## 3. Каталог и веса моделей распознавания речи (скачиваются пользователем)

Файлы моделей в бандл не входят: пользователь скачивает выбранные GGUF-модели в
настройках или при онбординге (из Hugging Face или зеркала `blob.handy.computer`).
Встроенный снимок каталога `Sources/Keyboop/Resources/models-catalog.json` и
опциональное онлайн-обновление списка синхронизируются с каталогом проекта
[Handy](https://github.com/cjpais/Handy) (отфильтрованы по поддержке русского
языка и совместимости с текущей версией `transcribe.cpp`).

Основные семейства и лицензии моделей каталога:
- **GigaAM v3** (SberDevices / Salute, GGUF-порт `handy-computer`) — **MIT**
- **NVIDIA Parakeet TDT / Canary** (GGUF-порт `handy-computer`) — **CC-BY-4.0**
- **NVIDIA Nemotron Streaming ASR** (GGUF-порт `handy-computer`) — **OpenMDW-1.1**
- **Whisper** (OpenAI / `handy-computer`) — **MIT / Apache-2.0**
- **Qwen3-ASR** (Alibaba / `handy-computer`) — **Apache-2.0**
- **Voxtral Realtime** (Mistral / `handy-computer`) — **Apache-2.0**
- **Orukeet** (`handy-computer`) — **CC-BY-SA-4.0**

Точная лицензия и ссылка на репозиторий указаны у каждой записи в
`Sources/Keyboop/Resources/models-catalog.json`.

## 4. Языковые данные (триграммы и словари RU/EN)

Файлы `Sources/Keyboop/Resources/trigrams_ru.json`, `trigrams_en.json`,
`words_ru.json`, `words_en.json` взяты из проекта **keyswitcher**
(<https://github.com/graninilya/keyswitcher>), лицензия MIT.

```
MIT License

Copyright (c) 2026 Ilya Granin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND...
```

## 5. Системные фреймворки Apple

`AppKit`, `Carbon` (Text Input Services), `CoreGraphics`, `IOKit`, `AVFoundation`,
`CoreAudio`, `AudioToolbox`, `Metal`, `MetalKit`, `Accelerate`, `SwiftUI`,
`Translation` и `FoundationModels` (weak-linked для Apple Intelligence на macOS 26+)
— системные компоненты macOS.

## Словари предиктивного ввода

`word_frequencies.json` содержит частоты слов из русской и английской выборок
OpenSubtitles 2018 проекта FrequencyWords (Hermit Dave). Keyboop преобразует
исходные списки в JSON и отбирает слова русского и английского алфавитов.
Производный файл распространяется под CC BY-SA 4.0.

- [FrequencyWords, снимок 525f9b5](https://github.com/hermitdave/FrequencyWords/tree/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018)
- [OpenSubtitles](https://www.opensubtitles.org/), P. Lison and J. Tiedemann, “OpenSubtitles2016: Extracting Large Parallel Corpora from Movie and TV Subtitles”, LREC 2016.
- [Лицензия CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

`next_words.json` использует данные WM Keyboard (Wasi Master). Взяты
`{ru,en}_bigrams.txt.gz` и `{ru,en}_trigrams.txt.gz` из каталогов соответствующих языков.
Исходные таблицы основаны на Leipzig Corpora Collection (Universität Leipzig,
CC BY 4.0) и предложениях участников Tatoeba (CC BY 2.0 FR / CC0). Keyboop
отбирает по одному продолжению и дополняет результат собственными фразами.

- [WM Keyboard, источники и лицензии по файлам](https://github.com/wasi-master/wmkeyboard-data/blob/663e989ac1de7505a103b2ebdbdc7aa6f4c4d9b5/data/README.md)
- [Leipzig Corpora Collection](https://wortschatz.uni-leipzig.de/en/download), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
- [Tatoeba и авторы предложений](https://tatoeba.org/en/downloads), [CC BY 2.0 FR](https://creativecommons.org/licenses/by/2.0/fr/), [CC0](https://creativecommons.org/publicdomain/zero/1.0/)

Для воспроизведения положите оба файла `{ru,en}_50k.txt` из FrequencyWords и
четыре архива WM Keyboard в один каталог и выполните
`python3 tools/import-prediction-dictionaries.py КАТАЛОГ Sources/Keyboop/Resources`.
Импорт проверяет SHA-256 каждого исходного файла.

## llama.cpp — локальный сервер предиктивного ввода

Keyboop запускает [llama.cpp](https://github.com/ggml-org/llama.cpp) отдельным процессом.
Сборка использует дистрибутивы llama.cpp b11490 для macOS с проверкой SHA-256.
Полный текст лицензии MIT включён в `Contents/Resources/Licenses/llama.cpp/`.
Для автономной разработки на Apple Silicon скрипт также поддерживает закреплённый
arm64-срез llama.cpp из Ollama 0.40.16 (ревизия 6c01da627), с лицензиями из того же пакета.
Веса языковых моделей скачиваются отдельно.

## SAGE Distilled 95M

SAGE Distilled 95M and its tokenizer are by ai-forever (MIT).
Keyboop downloads the tokenizer from the original model repository and the FP16
ONNX weights exported by krut42 (MIT). Each file is pinned to a repository
revision and verified against its SHA-256 before installation.

- [Original model and tokenizer](https://huggingface.co/ai-forever/sage-fredt5-distilled-95m)
- [FP16 ONNX export](https://huggingface.co/krut42/voice-sage95m-fp16)
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) (MIT). Its native
  library and accompanying notices are included under `Contents/Helpers/sage`
  and `Contents/Resources/Licenses`.

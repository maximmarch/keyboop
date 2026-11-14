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

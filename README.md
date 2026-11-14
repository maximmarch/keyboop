# Keyboop (`0.5.1 · Kinkajou`)

> **wrong layout? keyboop.**
> Бесплатный open-source переключатель раскладки и локальная голосовая диктовка
> для macOS — **не трогает буфер обмена** и не отправляет твой ввод и речь в облако.

Набрал `ghbdtn` вместо `привет`? Keyboop молча всё расколдует прямо во время
набора или по границе слова. Не угадал — поправь хоткеем: последнее слово,
последние N слов или всё, что набрано за последние T секунд. Плюс сниппеты,
правила ввода на уровне сайтов в Chrome, предсказание раскладки при
переключении окон и мощная офлайн-диктовка на базе `transcribe.cpp`.

> Этот репозиторий — форк [`iffuno/keyboop`](https://github.com/iffuno/keyboop) с
> веткой **0.5 · Kinkajou** (`0.5.1`): переходом на единый движок `transcribe.cpp`,
> каталогом русских ASR-моделей (включая GigaAM v3), локальной AI-постобработкой,
> паузным чанкингом, live-превью на острове, контекстными профилями приложений,
> правилами ввода на уровне сайтов в Chrome и диктовкой по клавише `Fn / 🌐`.
> Апстримный фид автообновлений (`SUFeedURL`) в форке отключён по умолчанию.

## Возможности

- 🧼 **Не ломает буфер обмена.** Keyboop печатает исправленный текст напрямую и не
  перетирает clipboard (в отличие от классических переключателей раскладки).
- 🧭 **Умная смена раскладки и откат.** Исправление на лету, откат последнего
  слова / N слов / окна времени, цикл раскладок и предсказание нужной раскладки
  при переключении фокуса между окнами и приложениями.
- 🎙 **Локальная диктовка на `transcribe.cpp`.** Единый GGUF-движок с Metal GPU на
  Apple Silicon и CPU/AVX2 на Intel. Каталог моделей с поддержкой русского языка
  прямо в настройках: **GigaAM v3** (по умолчанию), **Parakeet v3**, **Whisper
  Large v3 Turbo**, **Qwen3-ASR**, **Nemotron Streaming**, **Voxtral Realtime** и
  др., с обновлением списка моделей по кнопке.
- ✂️ **Очистка речи и нарезка по паузам.** Детерминированное удаление слов-паразитов
  и свёртывание заиканий, а длинная диктовка режется по естественным паузам и
  распознаётся в фоне ещё до отпускания клавиши.
- ✨ **On-device AI-постобработка.** Подключение встроенной модели **Apple
  Intelligence** (`FoundationModels`) или локального OpenAI-совместимого сервера
  (Ollama, LM Studio и др.) со своим системным промптом.
- 💬 **Live-превью речи на пилюле и Notch Island.** Промежуточный текст
  появляется прямо во время диктовки — через нативный поток на streaming-моделях
  или через паузные чанки и прерываемое быстрое превью на остальных.
- 🧩 **Контекстные профили по приложениям.** Автоматические правила для чатов,
  почты/документов, редакторов кода и терминалов (пунктуация, финальная точка,
  отдельный AI-промпт), плюс редактор своих правил.
- 🌐 **Правила ввода на уровне сайтов (Google Chrome).** Отдельные правила для
  доменов (`github.com`) и поддоменов (`*.github.com`): автосмена раскладки,
  опечатки, сниппеты, предпочтительная раскладка (RU/EN) и режим исключения.
  Расширение в `Extensions/chrome` и нативный мост `KeyboopNativeHost` передают
  только домен активной вкладки (без полных URL, параметров и текста страниц;
  Инкогнито по умолчанию игнорируется).
- 🎙 **Диктовка по клавише `Fn / 🌐`.** Поддерживается удержание или переключение
  клавишей `Fn / 🌐` (при нажатии системной комбинации `Fn+<клавиша>` удержание
  безопасно сбрасывается).
- 🌍 **Перевод выделенного и сниппеты.** Офлайн-перевод выделенного текста
  через Apple Translation (macOS 15+) и автозамена сниппетов независимо от
  раскладки и регистра.

## Системные требования

- **Apple Silicon (M1 и новее):** macOS 14.0+ (распознавание речи ускоряется через Metal GPU).
- **Intel (`x86_64`):** macOS 13.0+ (распознавание идёт на CPU/AVX2 — работают
  все модели каталога `transcribe.cpp`, для быстрого отклика лучше выбирать
  компактные модели вроде GigaAM v3, Parakeet или Whisper Small).

## Сборка из исходников

Нужны **Xcode Command Line Tools** (`swiftc`, `actool`), `cmake` и две внешние
зависимости в папке `vendor/` (в git-историю они не входят):

### 1. `transcribe.cpp` (статическая сборка)

```bash
mkdir -p vendor
git clone https://github.com/handy-computer/transcribe.cpp vendor/transcribe.cpp

# Срез arm64 (Metal GPU, macOS 14+)
cmake -S vendor/transcribe.cpp -B vendor/transcribe.cpp/build-macos14 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DTRANSCRIBE_BUILD_SHARED=OFF \
  -DTRANSCRIBE_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build vendor/transcribe.cpp/build-macos14 --parallel
cmake --install vendor/transcribe.cpp/build-macos14 --prefix vendor/transcribe.cpp/install-macos14
```

⚠️ Флаг `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0` обязателен: без него `cmake` берёт
версию текущей macOS, и `ggml-metal` жёстко линкуется к системным символам, из-за
чего приложение падает до `main()` на macOS 14.

Если нужна universal-сборка с поддержкой Intel (`KEYBOOP_UNIVERSAL=1`),
дополнительно собери CPU-срез `x86_64`:

```bash
cmake -S vendor/transcribe.cpp -B vendor/transcribe.cpp/build-x86 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DTRANSCRIBE_BUILD_SHARED=OFF \
  -DTRANSCRIBE_METAL=OFF \
  -DTRANSCRIBE_X86_CONSERVATIVE=ON \
  -DGGML_AVX2=ON \
  -DGGML_FMA=ON \
  -DGGML_F16C=ON
cmake --build vendor/transcribe.cpp/build-x86 --parallel
cmake --install vendor/transcribe.cpp/build-x86 --prefix vendor/transcribe.cpp/install-x86
```

### 2. `Sparkle.framework`

Скачай [релиз Sparkle](https://github.com/sparkle-project/Sparkle/releases) и
положи `Sparkle.framework` в `vendor/sparkle/Sparkle.framework`.

### 3. Сборка приложения

```bash
# Dev-сборка с ad-hoc подписью → Keyboop.app (bundle id: ru.keyboop.app.dev)
KEYBOOP_SIGN_ID=- bash build-app.sh

# Сборка с локальным сертификатом "Keyboop Dev" (если создан в Keychain)
bash build-app.sh

# Сборка + чистая установка в /Applications и запуск
bash install-local.sh
```

Для релизной сборки с Developer ID и своим Sparkle-фидом при необходимости можно
передать `KEYBOOP_RELEASE=1` и `KEYBOOP_FEED_URL=https://...`.

## Авторы

- **Ivan Smetanin** ([`iffuno/keyboop`](https://github.com/iffuno/keyboop)) —
  оригинальная идея, продукт и основа Keyboop.
- **Maxim Marchuk** ([`maximmarch/keyboop`](https://github.com/maximmarch/keyboop)) —
  развитие форка `0.5.x · Kinkajou`: интеграция `transcribe.cpp` и каталога
  моделей с поддержкой русского языка, AI-постобработка, паузный чанкинг,
  live-превью, контекстные профили, правила для сайтов в Chrome и диктовка по `Fn`.

## Лицензия

MIT — см. [LICENSE](LICENSE) и [THIRD_PARTY.md](THIRD_PARTY.md).

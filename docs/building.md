# Сборка Keyboop на macOS

Понадобятся Xcode Command Line Tools, CMake и зависимости в `vendor/`.
Сборка упаковывает runtimes llama.cpp и ONNX Runtime с проверкой контрольных
сумм. Веса моделей загружаются отдельно из настроек приложения.

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
# Отдельная dev-сборка. Скрипт выведет путь к Keyboop.app.
KEYBOOP_BUILD_FRESH=1 KEYBOOP_SIGN_ID=- bash build-app.sh

# Проверка готового dev-бандла
bash script/check-app-bundle.sh /path/to/Keyboop.app

# Сборка с локальным сертификатом "Keyboop Dev" (если создан в Keychain)
bash build-app.sh

```

Для релизной сборки с Developer ID и своим Sparkle-фидом при необходимости можно
передать `KEYBOOP_RELEASE=1` и `KEYBOOP_FEED_URL=https://...`.

## Проверки

```bash
./script/test-build-destination.sh
./script/test-check-app-bundle.sh
./script/test-voice-history.sh
./script/test-clipboard-transfer.sh
./Tests/SageRuntime/run.sh
./Tests/WordCompletion/run.sh
./Tests/PredictionRuntime/run.sh
```

Наборы данных и команды для проверки качества подсказок описаны
в [руководстве по тестированию](../Tests/PredictionEval/README.md).

[Главная](../README.md)

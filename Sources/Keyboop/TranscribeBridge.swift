import Foundation
import os

/// Обёртка над `transcribe.cpp` (единый движок для GigaAM v3, Parakeet GGUF, Whisper, Qwen3-ASR, Canary и др.).
/// НЕ thread-safe — вызывать строго с одной очереди (`VoiceController.transcribeQueue`),
/// кроме `requestAbort()` / `clearAbort()`, которые потокобезопасны.
final class TranscribeBridge {
    private static let initBackendsOnce: Void = {
        _ = transcribe_init_backends_default()
    }()

    private final class AbortState {
        private var lock = os_unfair_lock_s()
        private var aborted = false

        func set(_ value: Bool) {
            os_unfair_lock_lock(&lock)
            aborted = value
            os_unfair_lock_unlock(&lock)
        }

        func get() -> Bool {
            os_unfair_lock_lock(&lock)
            let v = aborted
            os_unfair_lock_unlock(&lock)
            return v
        }
    }

    private static let abortCallback: transcribe_abort_callback = { userData in
        guard let userData else { return false }
        let state = Unmanaged<AbortState>.fromOpaque(userData).takeUnretainedValue()
        return state.get()
    }

    let modelPath: String
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private let abortState = AbortState()
    private var streamActive = false

    private(set) var arch = ""
    private(set) var variant = ""
    private(set) var backend = ""
    private(set) var supportedLanguages: [String] = []
    private(set) var supportsLanguageDetect = false
    private(set) var supportsInitialPrompt = false
    private(set) var supportsLongForm = false
    private(set) var supportsStreaming = false
    private(set) var acceptsWhisperExt = false
    private(set) var effectiveMaxAudioMs: Int64 = 0

    /// Оставляем 1 P-ядро свободным, чтобы фоновые системные потоки и аудио не заикались.
    private static let transcribeThreads: Int = {
        var pCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &pCores, &size, nil, 0) == 0, pCores > 0 {
            return max(1, Int(pCores) - 1)
        }
        return max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }()

    init?(modelPath: String, forceCPU: Bool = false) {
        _ = Self.initBackendsOnce
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        self.modelPath = modelPath
        guard load(forceCPU: forceCPU) else { return nil }
    }

    deinit {
        unloadHandles()
    }

    private func unloadHandles() {
        streamActive = false
        if let session {
            transcribe_set_abort_callback(session, nil, nil)
            transcribe_session_free(session)
            self.session = nil
        }
        if let model {
            transcribe_model_free(model)
            self.model = nil
        }
    }

    /// Безопасно с любого потока просит прервать текущий спекулятивный прогон распознавания.
    func requestAbort() {
        abortState.set(true)
    }

    /// Сбрасывает флаг отмены перед финальной транскрибацией.
    func clearAbort() {
        abortState.set(false)
    }

    private func load(forceCPU: Bool) -> Bool {
        unloadHandles()

        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = forceCPU ? TRANSCRIBE_BACKEND_CPU : TRANSCRIBE_BACKEND_AUTO

        var loadedModel: OpaquePointer?
        let loadStatus = modelPath.withCString { cPath in
            transcribe_model_load_file(cPath, &loadParams, &loadedModel)
        }
        guard loadStatus == TRANSCRIBE_OK, let loadedModel else {
            let statusStr = String(cString: transcribe_status_string(Int32(loadStatus.rawValue)))
            kbLog("transcribe: ошибка загрузки \(URL(fileURLWithPath: modelPath).lastPathComponent): \(statusStr)")
            return false
        }

        var sessParams = transcribe_session_params()
        transcribe_session_params_init(&sessParams)
        sessParams.n_threads = Int32(Self.transcribeThreads)

        var loadedSession: OpaquePointer?
        let sessStatus = transcribe_session_init(loadedModel, &sessParams, &loadedSession)
        guard sessStatus == TRANSCRIBE_OK, let loadedSession else {
            let statusStr = String(cString: transcribe_status_string(Int32(sessStatus.rawValue)))
            kbLog("transcribe: ошибка инициализации сессии: \(statusStr)")
            transcribe_model_free(loadedModel)
            return false
        }

        self.model = loadedModel
        self.session = loadedSession
        let abortPtr = Unmanaged.passUnretained(abortState).toOpaque()
        transcribe_set_abort_callback(loadedSession, Self.abortCallback, abortPtr)

        if let s = transcribe_model_arch_string(loadedModel) { arch = String(cString: s) }
        if let s = transcribe_model_variant_string(loadedModel) { variant = String(cString: s) }
        if let s = transcribe_model_backend(loadedModel) { backend = String(cString: s) }

        var caps = transcribe_capabilities()
        transcribe_capabilities_init(&caps)
        if transcribe_model_get_capabilities(loadedModel, &caps) == TRANSCRIBE_OK {
            supportsLanguageDetect = caps.supports_language_detect
            supportsStreaming = caps.supports_streaming
            if caps.n_languages > 0, let langsPtr = caps.languages {
                supportedLanguages = (0..<Int(caps.n_languages)).compactMap { idx in
                    langsPtr[idx].map { String(cString: $0) }
                }
            }
        }
        supportsInitialPrompt = transcribe_model_supports(loadedModel, TRANSCRIBE_FEATURE_INITIAL_PROMPT)
        supportsLongForm = transcribe_model_supports(loadedModel, TRANSCRIBE_FEATURE_LONG_FORM)
        acceptsWhisperExt = transcribe_model_accepts_ext_kind(loadedModel, TRANSCRIBE_EXT_SLOT_RUN, TRANSCRIBE_EXT_KIND_WHISPER_RUN)

        var limits = transcribe_session_limits()
        transcribe_session_limits_init(&limits)
        if transcribe_session_get_limits(loadedSession, &limits) == TRANSCRIBE_OK {
            effectiveMaxAudioMs = limits.effective_max_audio_ms
        }

        kbLog("transcribe: загружена \(URL(fileURLWithPath: modelPath).lastPathComponent) [arch=\(arch) backend=\(backend) stream=\(supportsStreaming) threads=\(Self.transcribeThreads)]")
        return true
    }

    /// Транскрибировать 16 kHz mono Float32 PCM. `language`: "ru" / "en" / "auto".
    func transcribe(samples: [Float], language: String) -> String {
        guard let session, !samples.isEmpty else { return "" }
        clearAbort()

        // Для семейств с жёстким контекстным потолком (Qwen3-ASR, Canary и т.д.) нарезаем
        // длинный клип безопасными кусками, чтобы не упереться в TRANSCRIBE_ERR_INPUT_TOO_LONG.
        if effectiveMaxAudioMs > 0, !supportsLongForm {
            let maxSamples = max(16_000 * 10, Int(Double(effectiveMaxAudioMs) * 0.85 * 16.0))
            if samples.count > maxSamples {
                return transcribeInChunks(samples: samples, maxSamples: maxSamples, language: language)
            }
        }

        return runSingleChunk(samples: samples, language: language, allowCPUFallback: true, activeSession: session)
    }

    /// Лёгкий прогон живого превью (не сбрасывает флаг отмены: если пользователь уже отпустил
    /// хоткей, превью тут же прерывается и возвращает nil, чтобы не задерживать финал).
    func transcribePreview(samples: [Float], language: String) -> String? {
        guard let session, !samples.isEmpty, !abortState.get() else { return nil }
        let out = runSingleChunk(samples: samples, language: language, allowCPUFallback: false, activeSession: session)
        if abortState.get() || transcribe_was_aborted(session) {
            return nil
        }
        return out
    }

    // MARK: - Нативный потоковый API transcribe.cpp

    func beginStream(language: String) -> Bool {
        guard let session, supportsStreaming else { return false }
        clearAbort()
        if streamActive {
            transcribe_stream_reset(session)
            streamActive = false
        }

        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)
        runParams.task = TRANSCRIBE_TASK_TRANSCRIBE
        runParams.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

        let hint = resolvedHintLanguage(for: language)
        let langC = hint.flatMap { strdup($0) }
        defer { if let langC { free(langC) } }
        if let langC { runParams.language = UnsafePointer(langC) }

        var streamParams = transcribe_stream_params()
        transcribe_stream_params_init(&streamParams)
        streamParams.commit_policy = TRANSCRIBE_STREAM_COMMIT_STABLE_PREFIX
        streamParams.stable_prefix_agreement_n = 2

        let status = transcribe_stream_begin(session, &runParams, &streamParams)
        guard status == TRANSCRIBE_OK else {
            let statusStr = String(cString: transcribe_status_string(Int32(status.rawValue)))
            kbLog("transcribe stream: ошибка старта status=\(statusStr) arch=\(arch)")
            return false
        }
        streamActive = true
        return true
    }

    func feedStream(samples: [Float]) -> (text: String, changed: Bool) {
        guard let session, streamActive, !samples.isEmpty else { return ("", false) }

        let safeSamples: [Float]
        if samples.allSatisfy({ $0.isFinite }) {
            safeSamples = samples
        } else {
            safeSamples = samples.map { $0.isFinite ? $0 : 0 }
        }

        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = safeSamples.withUnsafeBufferPointer { buf -> transcribe_status in
            guard let base = buf.baseAddress else { return TRANSCRIBE_ERR_INVALID_ARG }
            return transcribe_stream_feed(session, base, Int32(buf.count), &update)
        }
        guard status == TRANSCRIBE_OK else {
            if status != TRANSCRIBE_ERR_ABORTED {
                let statusStr = String(cString: transcribe_status_string(Int32(status.rawValue)))
                kbLog("transcribe stream: ошибка feed status=\(statusStr)")
            }
            transcribe_stream_reset(session)
            streamActive = false
            return ("", false)
        }
        guard update.result_changed else { return ("", false) }
        return (readStreamText(session: session), true)
    }

    func finalizeStream() -> String? {
        guard let session, streamActive else { return nil }
        defer {
            transcribe_stream_reset(session)
            streamActive = false
        }

        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = transcribe_stream_finalize(session, &update)
        let acceptable = (status == TRANSCRIBE_OK || status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_OUTPUT_REPETITION)
        guard acceptable else {
            let statusStr = String(cString: transcribe_status_string(Int32(status.rawValue)))
            kbLog("transcribe stream: ошибка finalize status=\(statusStr)")
            return nil
        }
        return readStreamText(session: session)
    }

    func cancelStream() {
        guard let session else { return }
        if streamActive || transcribe_stream_get_state(session) != TRANSCRIBE_STREAM_IDLE {
            transcribe_stream_reset(session)
        }
        streamActive = false
    }

    private func readStreamText(session: OpaquePointer) -> String {
        var textOut = transcribe_stream_text()
        transcribe_stream_text_init(&textOut)
        if transcribe_stream_get_text(session, &textOut) == TRANSCRIBE_OK, let full = textOut.full_text {
            return String(cString: full)
        }
        if let cText = transcribe_full_text(session) {
            return String(cString: cText)
        }
        return ""
    }

    private func transcribeInChunks(samples: [Float], maxSamples: Int, language: String) -> String {
        let overlap = 16_000 / 2   // 0.5 c перекрытия
        let step = max(16_000, maxSamples - overlap)
        var offset = 0
        var parts: [String] = []
        while offset < samples.count {
            guard let activeSession = session else { break }
            let end = min(samples.count, offset + maxSamples)
            let slice = Array(samples[offset..<end])
            let piece = runSingleChunk(samples: slice, language: language, allowCPUFallback: true, activeSession: activeSession)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { parts.append(piece) }
            if end >= samples.count { break }
            offset += step
        }
        return parts.joined(separator: " ")
    }

    private func resolvedHintLanguage(for setting: String) -> String? {
        guard setting != "auto" else { return nil }
        if supportedLanguages.isEmpty { return setting }
        if supportedLanguages.contains(setting) { return setting }
        if let prefixMatch = supportedLanguages.first(where: { $0.hasPrefix(setting + "-") }) {
            return prefixMatch
        }
        kbLog("transcribe: модель \(arch) не поддерживает hint языка '\(setting)' — запускаю без принудительного языка")
        return nil
    }

    private func runSingleChunk(samples: [Float], language: String, allowCPUFallback: Bool, activeSession: OpaquePointer) -> String {
        let t0 = CFAbsoluteTimeGetCurrent()
        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)
        runParams.task = TRANSCRIBE_TASK_TRANSCRIBE
        runParams.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

        let hint = resolvedHintLanguage(for: language)
        let langC = hint.flatMap { strdup($0) }
        defer { if let langC { free(langC) } }
        if let langC { runParams.language = UnsafePointer(langC) }

        var prompt = ""
        var promptC: UnsafeMutablePointer<CChar>?
        defer { if let promptC { free(promptC) } }
        var whisperExt = transcribe_whisper_run_ext()
        if acceptsWhisperExt && supportsInitialPrompt {
            let promptLang = WhisperPrompt.promptLanguage(setting: language == "auto" ? "auto" : (hint ?? language), detected: nil, p: 0)
            prompt = Self.punctuationPrompt(for: promptLang)
            if !prompt.isEmpty {
                promptC = strdup(prompt)
                transcribe_whisper_run_ext_init(&whisperExt)
                whisperExt.initial_prompt = UnsafePointer(promptC)
                whisperExt.prompt_condition = TRANSCRIBE_WHISPER_PROMPT_FIRST_SEGMENT
            }
        }

        let status: transcribe_status = samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return TRANSCRIBE_ERR_INVALID_ARG }
            if promptC != nil {
                return withUnsafePointer(to: &whisperExt) { extPtr in
                    extPtr.withMemoryRebound(to: transcribe_ext.self, capacity: 1) { baseExt in
                        runParams.family = baseExt
                        return transcribe_run(activeSession, base, Int32(buf.count), &runParams)
                    }
                }
            } else {
                return transcribe_run(activeSession, base, Int32(buf.count), &runParams)
            }
        }

        if status == TRANSCRIBE_ERR_BACKEND && allowCPUFallback && backend != "cpu" {
            kbLog("transcribe: ошибка GPU backend (\(backend)), перегружаю на CPU")
            if load(forceCPU: true), let cpuSession = session {
                return runSingleChunk(samples: samples, language: language, allowCPUFallback: false, activeSession: cpuSession)
            }
            return ""
        }

        let acceptable = (status == TRANSCRIBE_OK || status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_OUTPUT_REPETITION)
        guard acceptable else {
            let statusStr = String(cString: transcribe_status_string(Int32(status.rawValue)))
            kbLog("transcribe: ошибка запуска status=\(statusStr) arch=\(arch) samples=\(samples.count)")
            return ""
        }

        guard let cText = transcribe_full_text(activeSession) else { return "" }
        let rawOut = String(cString: cText)
        let detected = transcribe_detected_language(activeSession).map { String(cString: $0) } ?? ""
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let langInfo = detected.isEmpty ? (hint ?? "auto") : "\(hint ?? "auto")→\(detected)"
        kbLog("transcribe: \(arch)[\(backend)] lang=\(langInfo) samples=\(samples.count) за=\(elapsedMs)мс sym=\(rawOut.count)")

        if !prompt.isEmpty {
            let (stripped, cut) = WhisperPrompt.stripEcho(rawOut, prompt: prompt)
            if cut > 0 { kbLog("transcribe: срезано эхо initial_prompt (\(cut))") }
            return stripped
        }
        return rawOut
    }

    private static var lastHintCount = -1
    private static let promptMaxChars = 600

    private static func punctuationPrompt(for language: String) -> String {
        guard let (head, tail) = WhisperPrompt.blocks(for: language) else { return "" }
        var dict = ""
        if let words = VoiceDictionary.shared.recognitionHint() {
            let count = words.split(separator: ",").count
            if lastHintCount != count {
                lastHintCount = count
                kbLog("voice: в подсказку распознавания подмешано \(count) слов из словаря диктовки")
            }
            dict = language == "en" ? " Words that often come up: \(words)." : " Часто встречаются слова: \(words)."
        }
        let full = head + dict + tail
        if full.count <= Self.promptMaxChars { return full }
        return head + tail
    }
}

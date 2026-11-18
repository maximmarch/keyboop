import AppKit
import AVFoundation

/// Оркестратор голосового ввода (диктовка): hold-хоткей → запись → transcribe.cpp →
/// вставка БЕЗ буфера (принцип №1). Всё локально, без сети (принцип №2).
final class VoiceController {
    static let shared = VoiceController()
    private let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private let layout = LayoutManager()
    private var engine: TranscribeBridge?
    private var loadedModelId = ""
    private var starting = false   // begin() уже запустил async-старт — не запускать второй (гонка)
    private var abortStart = false // end()/cancel() пришёл во время async-старта → прервать его
    /// СИНХРОННЫЙ флаг намерения: true с момента begin() и до остановки записи. Источник истины
    /// для toggle (EventTap), т.к. begin() асинхронный и recorder.isRecording в момент toggle ещё false.
    /// Прокси к атомарному VoiceGate: колбэк CGEventTap читает это СИНХРОННО, а сам begin/end
    /// уезжает на main (см. VoiceGate — там причина). Семантика прежняя: «намерение записывать».
    var isActive: Bool { VoiceGate.isActive }
    /// Сериализация транскрипции: новая ЗАПИСЬ может начаться, пока прошлая транскрибируется
    /// (запись и whisper независимы), но сами whisper-вызовы — строго по одному (не реентерабельно).
    /// ⚠️ QoS ЗАДАН ЯВНО (01.08.2026). Без него очередь получала неопределённый приоритет и для
    /// планировщика была равна интерактивной работе — а распознавание занимает все выделенные ядра
    /// на секунды. Отсюда заикание звука в других программах во время диктовки.
    /// Берём `.userInitiated`, а НЕ `.utility`: человек нажал хоткей и ждёт результат, поэтому нам
    /// нужны производительные ядра. `.utility` на Apple Silicon уводит поток на экономичные, и
    /// распознавание стало бы втрое дольше — это ухудшение, а не улучшение.
    private let transcribeQueue = DispatchQueue(label: "ru.keyboop.voice.transcribe", qos: .userInitiated)
    private var transcribing = 0   // сколько клипов сейчас в транскрипции (для индикатора)
    private var transcribeGen = 0              // генерации задач транскрипции (main-only)
    private var liveTranscriptions = Set<Int>()  // ещё не завершившиеся генерации (main-only)
    /// Поколения, которые надо положить ТОЛЬКО в историю, без вставки в поле (отмена по Escape, R37).
    private var historyOnlyGens = Set<Int>()
    /// Разовый запрос AI-постобработки для текущей диктовки (зажатый отдельный AI-хоткей).
    private var sessionForcePostProcess = false
    /// Активное приложение в момент начала диктовки (для контекстных профилей).
    private var sessionTargetBundleID = ""
    /// Фоновая нарезка длинных диктовок на естественных паузах во время записи.
    private var pauseSession: LivePauseSession?

    // MARK: - Live HUD (нативный стриминг + безопасный превью-драфт)

    private var recordingSessionToken = 0
    private let liveLock = NSLock()
    private var nativeStreamSessionId = 0
    private var nativeStreamStarted = false
    private var nativeStreamSamples: [Float] = []
    private var nativeStreamDrainScheduled = false
    private var previewSessionId = 0
    private var previewTailSamples: [Float] = []
    private var previewCommittedPrefix = ""
    private var previewLastAttemptAt: CFAbsoluteTime = 0
    private var previewLastSampleCount = 0
    private var previewInFlight = false
    private var lastLiveHudText = ""
    private let abortBridgeLock = NSLock()
    private weak var abortBridgeRef: TranscribeBridge?

    /// Снять невостребованную пометку «только в историю».
    ///
    /// Ставится она при отмене на СЛЕДУЮЩЕЕ поколение (`transcribeGen + 1`) в расчёте, что его
    /// заведёт текущая запись. Если запись до расшифровки не дошла, поколение не создаётся и метка
    /// остаётся ждать чужую диктовку. Зовётся из каждой ветки раннего выхода `end()`.
    private func dropPendingHistoryOnly() {
        if historyOnlyGens.remove(transcribeGen + 1) != nil {
            kbLog("voice: снял невостребованную пометку «только в историю» (запись не дошла до расшифровки)")
        }
    }

    enum State { case idle, recording, processing }
    var onStateChange: ((State) -> Void)?

    private init() {
        recorder.setLevelHook { rms in
            VoiceIndicator.shared.pushLevel(rms)
            MenuBarController.shared?.pushLevel(rms)
        }
        recorder.onNotice = { msg in VoiceIndicator.shared.showToast(msg) }
        recorder.onDied = { [weak self] in
            guard let self else { return }
            kbLog("voice: запись оборвалась (вход недоступен) — диктовка завершена")
            VoiceGate.set(false)
            self.invalidateLiveSession()
            self.requestCurrentBridgeAbort()
            self.recorder.setChunkHook(nil)
            self.recorder.setDraftHook(nil)
            self.recorder.setPauseChunkHook(nil)
            self.pauseSession?.cancel()
            self.pauseSession = nil
            self.cancelNativeStreamOnQueue()
            self.sessionForcePostProcess = false
            self.playCue(self.failSound)
            self.setState(.idle)
        }
        setupMemoryPressureUnload()
    }

    /// ОСНОВНОЙ триггер выгрузки модели (~1.5 ГБ): системный memory pressure, а не таймер.
    /// Урок регрессии 0.2.58 (баг-репорт): выгрузка по 5-минутному будильнику заставляла
    /// перегружать модель почти на каждую диктовку (750–1550мс + всплеск аллокации 1.5 ГБ + циклы
    /// init/free Metal-контекста ggml) — «стало дольше и подтормаживает». Правильная семантика:
    /// пока памяти хватает — модель живёт (мгновенная диктовка); система прижала память (.warning/
    /// .critical) и мы простаиваем — отдаём немедленно. Таймер остаётся страховкой на долгий простой.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastVoiceUseAt = Date.distantPast   // последняя диктовка (main-only) — для анти-карусели
    private func setupMemoryPressureUnload() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.engine != nil, self.transcribing == 0, !self.isActive, !self.recorder.isRecording
            else { return }   // заняты диктовкой — не дёргаем; таймер/следующее событие доберёт
            // КАРУСЕЛЬ ПЕРЕЗАГРУЗОК (баг-репорт): крупная модель сама создаёт
            // warning-давление → мы выгружаем → следующая диктовка платит за перезагрузку →
            // снова давление, по кругу каждые полчаса. Warning в течение 10 минут после последней
            // диктовки игнорируем — пользователь РАБОТАЕТ; по warning выгружаем только в простое.
            // Critical уважаем всегда: системе реально плохо — отдаём немедленно.
            let ev = DispatchSource.MemoryPressureEvent(rawValue: self.memoryPressureSource?.data ?? 0)
            if !ev.contains(.critical), Date().timeIntervalSince(self.lastVoiceUseAt) < 600 {
                kbLog("voice: memory warning в активной сессии диктовок — модель НЕ выгружаю")
                return
            }
            self.modelIdleRelease?.cancel(); self.modelIdleRelease = nil
            self.transcribeQueue.async { [weak self] in
                self?.unloadEngineOnQueue()
                kbLog("voice: системе не хватает памяти (pressure) — модель выгружена")
            }
        }
        src.resume()
        memoryPressureSource = src
    }

    /// Предзагрузка модели в фоне (на старте приложения, если голос включён и модель есть) — чтобы
    /// ПЕРВОЕ нажатие диктовки не платило за загрузку.
    func preload() {
        guard settings.voiceEnabled, hasUsableModel else { return }
        DispatchQueue.global(qos: .utility).async { _ = AVCaptureDevice.default(for: .audio) }
        if settings.voiceUnloadAfterDictation {
            kbLog("voice: прогрев модели пропущен — включена выгрузка после каждой диктовки")
            releaseModelsNow()
            return
        }
        let targetId = effectiveModelId()
        transcribeQueue.async { [weak self] in
            self?.loadModelIfNeeded(targetId)
            DispatchQueue.main.async { self?.scheduleModelRelease() }
        }
    }

    // MARK: - Модель

    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func modelPath(_ name: String) -> String {
        ModelDownloader.resolvedModelPath(for: name)
    }
    private func effectiveModelId() -> String {
        if ModelDownloader.shared.isInstalled(settings.voiceModel) { return settings.voiceModel }
        if let installed = ModelDownloader.firstInstalledModelId() { return installed }
        return settings.voiceModel
    }
    var modelInstalled: Bool { ModelDownloader.shared.isInstalled(settings.voiceModel) }
    var hasUsableModel: Bool {
        modelInstalled || ModelDownloader.firstInstalledModelId() != nil
    }
    /// Зовётся, когда диктовку нажали, а модели нет — UI предложит скачать.
    var onNeedModel: (() -> Void)?

    // MARK: - Hold-to-talk

    /// Зажали хоткей диктовки. ВАЖНО: НЕ блокируем по «идёт транскрипция прошлого клипа» — запись и
    /// whisper независимы (баг «не сработало с первого раза»: новую запись глушил busy предыдущей).
    func begin(forcePostProcess: Bool = false) {
        guard settings.voiceEnabled else { return }
        if starting { kbLog("voice: begin пропущен — старт уже идёт"); return }
        if recorder.isRecording { kbLog("voice: begin пропущен — запись уже идёт"); return }
        VoiceGate.set(true)            // СИНХРОННО: намерение записывать — toggle сразу видит активность
        starting = true
        abortStart = false
        sessionForcePostProcess = forcePostProcess
        sessionTargetBundleID = Engine.frontmostBundleID()
        lastVoiceUseAt = Date()        // маркер «пользователь диктует» для анти-карусели pressure-выгрузки
        Task { @MainActor in
            defer { starting = false }
            // Доступ к микрофону — ПЕРВЫМ (даже без модели), чтобы новый юзер увидел системный промпт.
            guard await AudioRecorder.requestAccess() else {
                kbLog("voice: нет доступа к микрофону"); Sounds.beep(); VoiceGate.set(false); sessionForcePostProcess = false; return
            }
            if abortStart { kbLog("voice: старт прерван (отпустили до начала записи)"); VoiceGate.set(false); sessionForcePostProcess = false; setState(.idle); return }
            guard hasUsableModel else {
                kbLog("voice: нет модели распознавания — предлагаем скачать")
                VoiceGate.set(false); sessionForcePostProcess = false; onNeedModel?(); return
            }
            // Загрузка модели — строго на transcribeQueue, НЕ на @MainActor.
            // whisper_init_from_file_with_params() читает модель с диска (75–1500+ МБ) несколько секунд.
            // Вызов на main thread замораживал RunLoop: CGEventTap переставал отвечать → весь ввод
            // (мышь, клавиатура) зависал до конца загрузки. Serializes с preload() — оба на одной очереди.
            // ТОЛЬКО если диктовать будет whisper. Раньше грузили безусловно — при движке Parakeet
            // (дефолт!) это впустую тянуло с диска 1.5 ГБ и задерживало старт записи на секунды,
            // а в dev-домене (модель `small` не скачана) давало «модель не загрузилась» на каждой
            // диктовке. Parakeet свою модель грузит сам в transcribe() и греется в preload().
            //
            // БЕЗ ОЖИДАНИЯ (баг-репорт: «старт диктовки стал дольше»): раньше begin() ждал
            // загрузку ЦЕЛИКОМ (large-v3-turbo ~1.2с) и только потом включал микрофон. Записи модель
            // не нужна, а транскрипция встаёт на transcribeQueue ПОЗАДИ загрузки — порядок гарантирует
            // сама очередь. Параллельно: старт мгновенный, загрузка прячется под время речи.
            let activeId = effectiveModelId()
            transcribeQueue.async { [weak self] in self?.loadModelIfNeeded(activeId) }
            if abortStart { VoiceGate.set(false); sessionForcePostProcess = false; setState(.idle); return }
            MicVolume.raiseIfEnabled()
            do {
                try recorder.start()
                if abortStart {        // отпустили ровно в момент старта — стоп немедленно
                    _ = recorder.stop(); VoiceGate.set(false); sessionForcePostProcess = false; setState(.idle); return
                }
                self.recordingSessionToken &+= 1
                let sessionToken = self.recordingSessionToken
                let streamLang = self.languageForTranscribe()
                let wantStreamingHUD = self.settings.voiceStreaming
                let nativeStreamCapable = wantStreamingHUD
                    && (ModelDownloader.model(id: activeId)?.capabilities.streaming == true)

                self.configureLiveSession(
                    sessionToken: sessionToken,
                    language: streamLang,
                    modelId: activeId,
                    wantStreamingHUD: wantStreamingHUD,
                    nativeStreamCapable: nativeStreamCapable
                )
                setState(.recording)
                playCue(startSound)    // восходящее «тук-тук» — пошла запись
            } catch {
                kbLog("voice: старт записи не удался: \(error)")
                self.invalidateLiveSession()
                self.recorder.setChunkHook(nil)
                self.recorder.setDraftHook(nil)
                self.recorder.setPauseChunkHook(nil)
                self.pauseSession?.cancel()
                self.pauseSession = nil
                self.cancelNativeStreamOnQueue()
                sessionForcePostProcess = false
                VoiceGate.set(false); setState(.idle)
            }
        }
    }

    /// Отпустили хоткей — стоп, транскрипция, вставка.
    func end() {
        // Отпустили/нажали стоп ДО того как async-begin реально завёл запись — прерываем старт.
        if starting && !recorder.isRecording {
            abortStart = true; VoiceGate.set(false); sessionForcePostProcess = false; dropPendingHistoryOnly()
            kbLog("voice: end во время старта — прерываю запуск (запись ещё не пошла)")
            return
        }
        guard recorder.isRecording else { VoiceGate.set(false); sessionForcePostProcess = false; dropPendingHistoryOnly(); return }
        noteSendGesture()         // правый ⌘ в момент отпускания = «отправить» (задача 124)
        let wantPostProcess = settings.voicePostProcessEnabled || sessionForcePostProcess
        let wantProofreading = settings.sageEnabled && settings.voiceSageProofreading && SageRuntime.shared.state == .ready
        sessionForcePostProcess = false
        let targetBundleID = sessionTargetBundleID
        recordingSessionToken &+= 1
        let (usedNativeStream, trailingStreamSamples) = consumeNativeStreamTrailing()
        invalidateLiveSession()
        requestCurrentBridgeAbort()
        recorder.setChunkHook(nil)
        recorder.setDraftHook(nil)
        recorder.setPauseChunkHook(nil)
        let activePauseSession = pauseSession
        pauseSession = nil
        let samples = recorder.stop()
        // Отсчёт «сколько человек ждал»: от отпускания клавиши до текста в поле. Время самого
        // whisper пишет WhisperBridge, но оно отвечает лишь за часть ожидания, а спрашивают всегда
        // про всё ожидание целиком.
        stopStamp = CFAbsoluteTimeGetCurrent()
        VoiceGate.set(false)      // ЗАПИСЬ окончена → можно сразу начинать НОВУЮ (транскрипция идёт в фоне)
        playCue(stopSound)    // нисходящее «тук-тук» — запись остановлена (до транскрипции)
        let rms = samples.isEmpty ? 0 : (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        kbLog("voice: \(samples.count) сэмплов, \(String(format: "%.1f", recorder.duration))с, RMS=\(String(format: "%.4f", rms))")
        // ⚠️ ПОМЕТКА «ТОЛЬКО В ИСТОРИЮ» ОБЯЗАНА СНИМАТЬСЯ НА КАЖДОМ ВЫХОДЕ ОТСЮДА (баг-репорт,
        // 03.08.2026, подтверждён логом трижды).
        //
        // Симптом: диктовка распознана, лежит в истории, копируется, но в поле не вставилась.
        // Причина: отмена по Escape метит СЛЕДУЮЩЕЕ поколение (`transcribeGen + 1`) в расчёте, что
        // его заберёт текущая запись. Но если запись до расшифровки не доходит — а после случайного
        // Escape она как раз почти всегда тихая, потому что человек уже молчит — поколение никто не
        // забирает, и метка висит. Её подбирает следующая, ни в чём не повинная диктовка, и молча
        // уезжает в историю вместо поля. В логе это выглядело так:
        //   16:51:40  отмена (Escape)
        //   16:51:40  тишина — пропуск            ← поколение не создано, метка осталась
        //   16:52:00  отменённая диктовка сохранена, 45 симв.   ← съело ЧУЖУЮ диктовку
        // Разрыв доходил до двух минут, поэтому связь никак не читалась.
        //
        // Escape тут не виноват: у автора хоткей диктовки ⌥`, а тильда прямо под Escape, задеть её
        // проще простого. Цена случайного нажатия должна быть нулевой, а не «съем следующую».
        //
        // ⚠️ Снимаем метку ТОЛЬКО в ветках раннего выхода, а НЕ здесь, до проверок. Отмена по
        // Escape зовёт `end()` сразу после того, как поставила метку, и снятие в начале функции
        // убило бы саму функцию «Отменённую всё равно сохранять»: текст поехал бы в поле, чего
        // человек как раз и не просил.

        // Слишком короткое нажатие (< 0.3 c) — просто отмена, без шума.
        guard recorder.duration >= 0.3 else {
            activePauseSession?.cancel()
            if usedNativeStream { cancelNativeStreamOnQueue() }
            dropPendingHistoryOnly()
            kbLog("voice: слишком коротко (\(String(format: "%.2f", recorder.duration))с) — отмена")
            recorder.releaseNow()   // отзыв #114: отброшенный подход не должен держать микрофон тёплым
            refreshIndicator(); return
        }
        // Тишина (нет сигнала) — не зовём whisper (иначе галлюцинации «Продолжение следует»).
        guard rms > 0.001 else {
            activePauseSession?.cancel()
            if usedNativeStream { cancelNativeStreamOnQueue() }
            dropPendingHistoryOnly()
            kbLog("voice: тишина (RMS \(String(format: "%.4f", rms))) — пропуск (микрофон молчал — мог быть занят другим приложением)")
            recorder.releaseNow()   // то же, что и у слишком короткой: держать микрофон не за чем
            refreshIndicator(); playCue(failSound)
            return
        }
        let lang = languageForTranscribe()
        let activeId = effectiveModelId()
        let cold = (engine == nil || loadedModelId != activeId)
        let contextDecision = VoiceContextProfileStore.shared.resolve(
            bundleID: targetBundleID,
            enabled: settings.voiceContextProfilesEnabled,
            globalNoFinalPeriod: settings.voiceNoFinalPeriod,
            globalNoCapital: settings.voiceNoCapital,
            globalNoEmDash: settings.voiceNoEmDash,
            globalPrompt: settings.voicePostProcessPrompt
        )
        if contextDecision.isProfileApplied {
            kbLog("voice: профиль=\(contextDecision.category.rawValue) (\(contextDecision.appName.isEmpty ? contextDecision.bundleID : contextDecision.appName))")
        }
        let extraBudget = (wantPostProcess ? 18.0 : 0) + (wantProofreading ? SageRuntime.dictationBudget : 0)
        let gen = beginTranscription(duration: recorder.duration, coldLoad: cold, extraBudget: extraBudget)
        refreshIndicator()   // НЕ setState(.processing) напрямую: отменённую диктовку считаем молча

        kbLog("voice: transcribe.cpp · модель=\(activeId) язык=\(lang) cold=\(cold) stream=\(usedNativeStream) aiPost=\(wantPostProcess)")
        Task { [weak self] in
            guard let self else { return }
            var text = ""
            if let activePauseSession, let assembled = await activePauseSession.finishAndAssemble() {
                text = assembled
                kbLog("voice: pause-chunking собрал \(assembled.count) симв.")
            } else if usedNativeStream,
                      let streamed = await self.finishNativeStreamOnQueue(trailingSamples: trailingStreamSamples,
                                                                          fallbackSamples: samples,
                                                                          language: lang,
                                                                          modelId: activeId) {
                text = streamed
                kbLog("voice: stream финал \(streamed.count) симв.")
            } else {
                text = await self.transcribeWithEngine(samples: samples, language: lang, modelId: activeId)
            }

            let ghostsCleaned = WhisperGhosts.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = VoiceTextCleaner.clean(
                ghostsCleaned,
                languageHint: lang,
                removeFillers: self.settings.voiceRemoveFillers,
                collapseStutters: self.settings.voiceCollapseStutters
            )
            var corrected = cleaned
            if wantProofreading, SageCorrectionText.supports(cleaned),
               await MainActor.run(body: { self.shouldProofread(gen) }) {
                await MainActor.run {
                    VoiceIndicator.shared.showProcessing(L10n.t("voice.sage.checking"))
                }
                corrected = await SageRuntime.shared.correctDictation(cleaned) {
                    await MainActor.run { self.shouldProofread(gen) }
                }
            }
            var finalText = VoiceDictionary.shared.apply(corrected)
            var showFallbackToast = false

            if wantPostProcess && !finalText.isEmpty {
                let shouldRunLLM = await MainActor.run {
                    self.liveTranscriptions.contains(gen) && !self.historyOnlyGens.contains(gen)
                }
                if shouldRunLLM {
                    await MainActor.run {
                        VoiceIndicator.shared.showProcessing(L10n.t("voice.enhancing"))
                    }
                    switch await VoicePostProcessor.shared.process(
                        finalText,
                        prompt: contextDecision.postProcessPromptOverride,
                        languageHint: lang
                    ) {
                    case .success(let enhanced):
                        finalText = enhanced
                        kbLog("voice: ai-post (\(self.settings.voicePostProcessProvider)) → \(enhanced.count) симв.")
                    case .failure(let err):
                        if case .cancelled = err { break }
                        if case .emptyInput = err { break }
                        kbLog("voice: ai-post отказ (\(err.message)) — отдаю исходный текст")
                        showFallbackToast = true
                    }
                }
            }

            // Кодируем и шифруем в фоне, а не на main.
            let clip = VoiceClips.save(samples: samples)
            let deliveredText = finalText
            let triggerFallbackToast = showFallbackToast
            await MainActor.run {
                guard self.endTranscription(gen) else { clip.map { VoiceClips.delete($0.id) }; return }
                let historyOnly = self.historyOnlyGens.remove(gen) != nil
                self.deliver(
                    deliveredText,
                    historyOnly: historyOnly,
                    alreadyCleaned: true,
                    languageHint: lang,
                    contextDecision: contextDecision,
                    audio: clip?.id,
                    wave: clip?.wave
                )
                self.refreshIndicator()
                if triggerFallbackToast && !historyOnly {
                    VoiceIndicator.shared.showToast(L10n.t("voice.postprocess.fallbackToast"))
                }
                self.scheduleModelRelease()
            }
        }
    }

    @MainActor
    private func shouldProofread(_ generation: Int) -> Bool {
        settings.sageEnabled && settings.voiceSageProofreading &&
            liveTranscriptions.contains(generation) && !historyOnlyGens.contains(generation)
    }

    private func transcribeWithEngine(samples: [Float], language: String, modelId: String) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            self.transcribeQueue.async { [weak self] in
                guard let self else { return c.resume(returning: "") }
                self.loadModelIfNeeded(modelId)
                guard let bridge = self.engine else { return c.resume(returning: "") }
                c.resume(returning: bridge.transcribe(samples: samples, language: language))
            }
        }
    }

    private func beginTranscription(duration: Double, coldLoad: Bool = false, extraBudget: Double = 0) -> Int {
        transcribing += 1
        transcribeGen += 1
        let gen = transcribeGen
        liveTranscriptions.insert(gen)
        var timeout = min(90, max(15, duration * 1.5)) + extraBudget
        if coldLoad { timeout += 60 }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.liveTranscriptions.remove(gen) != nil else { return }
            self.transcribing -= 1
            self.historyOnlyGens.remove(gen)
            kbLog("voice: транскрипция №\(gen) висит >\(Int(timeout))с — бросаю (поздний результат отброшу)")
            VoiceIndicator.shared.showToast(L10n.t("voice.stuck"))
            self.refreshIndicator()
            self.transcribeQueue.async { [weak self] in
                self?.unloadEngineOnQueue()
            }
        }
        return gen
    }

    /// true = задача ещё живая (сторож не срабатывал) — результат можно доставлять.
    private func endTranscription(_ gen: Int) -> Bool {
        guard liveTranscriptions.remove(gen) != nil else { return false }
        transcribing -= 1
        return true
    }

    /// Индикатор после события: если сейчас пишем — recording; если ещё идёт транскрипция — processing;
    /// иначе — idle. Чтобы back-to-back диктовки не схлопывали индикатор раньше времени.
    ///
    /// ⚠️ ОТМЕНЁННАЯ ДИКТОВКА РАСПОЗНАЁТСЯ МОЛЧА (автор 31.07). Человек нажал Escape — для него
    /// диктовка закончилась, и всплывающая следом плашка «Распознаю» выглядит так, будто отмена не
    /// сработала. Текст всё равно посчитается и ляжет в историю, просто без показа процесса.
    /// Считаем по МНОЖЕСТВАМ, а не по счётчику: пока молчаливая расшифровка считается, человек уже
    /// мог начать обычную диктовку, и её плашку прятать нельзя. Плашка нужна, только если есть хотя
    /// бы одна живая расшифровка, которую ждут в поле.
    /// Идёт ли ПРЯМО СЕЙЧАС запись или расшифровка, результат которой ждут в поле.
    ///
    /// Условие дословно то же, что у плашки (`refreshIndicator`), и это не совпадение: «плашка
    /// висит» и «результата ещё нет» — одно и то же состояние. Нужен вставке последней диктовки
    /// (задача 242): свежая запись ложится в историю ПОСЛЕ доставки текста, поэтому во время
    /// записи и расшифровки `lastVisible()` отдаёт ПРЕДЫДУЩУЮ диктовку — хоткей вставил бы вчерашний
    /// текст, а через секунду в то же поле приехал бы свежий, и человек разбирал бы склейку.
    /// ⚠️ Только с главного потока: `liveTranscriptions` main-only.
    var isBusyWithDictation: Bool {
        recorder.isRecording || liveTranscriptions.contains(where: { !historyOnlyGens.contains($0) })
    }

    private func refreshIndicator() {
        if recorder.isRecording { setState(.recording) }
        else if liveTranscriptions.contains(where: { !historyOnlyGens.contains($0) }) { setState(.processing) }
        else { setState(.idle) }
    }

    // Свои звуковые метки записи (CueSynth): восходящее «тук-тук» на старте,
    // нисходящее — на стопе. Отличаются от звука конвертации. Инстансы держим
    // в свойствах (локальный NSSound освободился бы и оборвал звук). Подчиняются
    // общему переключателю звука и громкости (settings.soundEnabled / soundVolume).
    private let startSound = NSSound(data: CueSynth.startData)
    private let stopSound  = NSSound(data: CueSynth.stopData)
    private let failSound  = NSSound(data: CueSynth.failData)
    private func playCue(_ sound: NSSound?) {
        guard settings.voiceSoundEnabled, !Sounds.allMuted, let sound else { return }
        // Ноль на ползунке = не играть вовсе (задача #60): иначе ползунок врёт, а звук «есть,
        // но не слышно» ещё и будит аудиоустройство.
        let vol = max(0, min(1, settings.voiceSoundVolume))
        guard vol > 0 else { return }
        sound.stop()   // на случай быстрого повторного вызова — переиграть с начала
        sound.volume = Float(vol)
        sound.play()
    }

    /// Отмена текущей диктовки (Escape) — запись отбрасываем, ничего не вставляем.
    func cancel() {
        if starting && !recorder.isRecording {   // отмена во время async-старта — прерываем запуск
            abortStart = true; VoiceGate.set(false)
            kbLog("voice: отмена во время старта — прерываю запуск")
            return
        }
        guard recorder.isRecording else { VoiceGate.set(false); return }
        // ОТМЕНА С СОХРАНЕНИЕМ В ИСТОРИЮ (R37, выключено по умолчанию). Человек просил: «нажал
        // Escape — пусть всё равно распознает и положит куда-нибудь». Идём ТЕМ ЖЕ путём, что и
        // обычное завершение, чтобы не заводить второй конвейер транскрипции со своими проверками
        // длительности, тишины и сторожем; отличие ровно одно и оно в самом конце — в поле ничего не
        // вставляем. Поколение помечаем в множестве, а не флагом: пока эта расшифровка считается,
        // человек уже может начать следующую диктовку, и перепутать их нельзя.
        if settings.escSaveToHistory {
            kbLog("voice: отмена (Escape) — распознаю и положу в историю, вставлять не буду")
            historyOnlyGens.insert(transcribeGen + 1)   // следующее поколение заведёт end()
            end()
            return
        }
        recordingSessionToken &+= 1
        invalidateLiveSession()
        requestCurrentBridgeAbort()
        recorder.setChunkHook(nil)
        recorder.setDraftHook(nil)
        recorder.setPauseChunkHook(nil)
        pauseSession?.cancel()
        pauseSession = nil
        cancelNativeStreamOnQueue()
        sessionForcePostProcess = false
        _ = recorder.stop()
        VoiceGate.set(false)
        refreshIndicator()
        playCue(failSound)   // мягкий нисходящий «отменено»
        kbLog("voice: диктовка отменена (Escape)")
    }

    /// Тихо обрывает текущее удержание (например, нажали Fn+<клавиша> — системное сочетание).
    func abortHold() {
        if starting && !recorder.isRecording {
            abortStart = true
            VoiceGate.set(false)
            sessionForcePostProcess = false
            return
        }
        recordingSessionToken &+= 1
        invalidateLiveSession()
        requestCurrentBridgeAbort()
        recorder.setChunkHook(nil)
        recorder.setDraftHook(nil)
        recorder.setPauseChunkHook(nil)
        pauseSession?.cancel()
        pauseSession = nil
        cancelNativeStreamOnQueue()
        sessionForcePostProcess = false
        if recorder.isRecording {
            _ = recorder.stop()
        }
        VoiceGate.set(false)
        refreshIndicator()
    }

    /// Текущее состояние записи (для кнопки в окне истории).
    var isRecording: Bool { recorder.isRecording }
    /// Запись по кнопке (toggle): не активна → старт; активна → стоп. Опирается на isActive
    /// (синхронный), а не isRecording — иначе быстрый второй тап во время async-старта рассинхронит.
    func toggleRecording() {
        if isActive { kbLog("voice: toggle → СТОП"); end() }
        else { kbLog("voice: toggle → СТАРТ"); begin() }
    }

    /// ФАЙЛ-МАРКЕР «ИДЁТ ДИКТОВКА» — для того, кто снаружи собирается нас прибить.
    ///
    /// ⚠️ Заведено по просьбе автора 17.08: агент разработки перезапускает dev-сборку десятки раз за
    /// сессию и не раз обрывал длинную диктовку на полуслове. Спрашивать состояние по IPC негде и
    /// незачем: наружу нужен один бит, и файл на диске это самый дешёвый способ его отдать любому
    /// скрипту. В маркере лежит время ПОСЛЕДНЕЙ активности — по нему `Tools/safe-quit.sh` выдерживает
    /// паузу после вставки текста, иначе перезапуск придётся ровно на момент, когда человек
    /// дочитывает вставленное и может докиктовать следом.
    static let busyMarker = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Keyboop/voice-busy")

    private func markBusy(_ busy: Bool) {
        let url = Self.busyMarker
        if busy {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? "\(Date().timeIntervalSince1970)".write(to: url, atomically: true, encoding: .utf8)
        } else {
            // Не удаляем, а перезаписываем временем окончания: пауза «несколько секунд после
            // вставки» считается именно от него.
            try? "\(Date().timeIntervalSince1970)".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Единая точка смены состояния: статус-бар (onStateChange) + плашка у курсора.
    private func setState(_ s: State) {
        onStateChange?(s)
        markBusy(s != .idle)
        // ГРОМКОСТЬ ПРИГЛУШАЕМ ЗДЕСЬ, а не рядом с recorder.start()/stop() (30.07). Выходов из
        // записи много: обычный конец, Escape, слишком короткое нажатие, тишина, смерть устройства,
        // прерванный старт. Развесить restore() по каждому — гарантированно забыть один и оставить
        // человеку тихий Mac. Смена состояния же одна на всех: ушли из .recording — вернули громкость.
        switch s {
        case .recording:
            if settings.voiceDuck { SystemVolume.duck(to: Float(settings.voiceDuckLevel) / 100) }
            VoiceIndicator.shared.showRecording()
        case .processing:
            SystemVolume.restore()          // распознавание идёт в фоне, слушать музыку уже можно
            VoiceIndicator.shared.showProcessing()
        case .idle:
            SystemVolume.restore()
            VoiceIndicator.shared.hide()
            // Выгрузка после диктовки ловится ЗДЕСЬ, а не только в конце доставки текста (ревью
            // 24.09): у записи много выходов без расшифровки — слишком короткое нажатие, тишина,
            // Escape, смерть устройства, прерванный старт, брошенная сторожем расшифровка. Модель
            // к тому моменту уже грузилась с нажатия, и без этой строки оставалась бы в памяти.
            // На следующий такт: флаги активности снимаются рядом с этим вызовом, пусть осядут.
            if settings.voiceUnloadAfterDictation {
                DispatchQueue.main.async { [weak self] in self?.releaseModelsNow() }
            }
        }
    }

    /// СКРЫТЫЙ ЖЕСТ «СКАЗАЛ И ОТПРАВИЛ» (задача 124, «для себя и друзей»).
    ///
    /// Держишь клавишу диктовки, договорил и, не отпуская её, дожимаешь ПРАВЫЙ ⌘ — распознанный
    /// текст встанет в поле и следом уйдёт Enter. В мессенджере это значит «сообщение отправлено».
    ///
    /// ⚠️ ПО УМОЛЧАНИЮ ВЫКЛЮЧЕН, И ЭТО ГЛАВНОЕ В ЗАДАЧЕ. Случайное совпадение у постороннего
    /// человека выглядело бы как «программа сама отправила недописанное сообщение» — худший класс
    /// сюрпризов, какой может выдать программа, живущая в чужой клавиатуре. Поэтому включение
    /// живёт только в настройках по имени ключа и в интерфейсе не показывается:
    ///
    ///     defaults write ru.keyboop.app voiceSendGesture -bool true
    ///
    /// Второе условие — диктовка должна висеть на УДЕРЖАНИИ модификатора. При «нажал-сказал-нажал»
    /// момента «отпускания с дожатым ⌘» просто не существует, и жест был бы случайным.
    private var sendGestureArmed = false

    private func noteSendGesture() {
        sendGestureArmed = false
        guard UserDefaults.standard.bool(forKey: "voiceSendGesture") else { return }
        guard settings.voiceHotkeyMode == "modkey" else { return }
        // ⚠️ Спрашиваем СОСТОЯНИЕ КЛАВИШ, а не флаги последнего события: событие отпускания придёт
        // позже и уже без ⌘. И именно правый: `maskCommand` горит от любого из двух, а бит
        // 0x000010 — device-dependent признак правой клавиши (тот же приём, что у сторон
        // модификаторов в EventTap).
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let rightCommand: UInt64 = 0x000010
        guard flags.rawValue & rightCommand != 0 else { return }
        sendGestureArmed = true
        kbLog("voice: жест отправки (правый ⌘) — после вставки нажму Enter")
    }

    /// Опции вывода (#41). Порядок важен: сначала убираем точку, потом регистр — иначе строка из
    /// одной буквы с точкой («А.») после снятия точки осталась бы заглавной.
    ///
    /// Точку снимаем ТОЛЬКО одиночную в самом конце и только её: «...» и «?»/«!» не трогаем, они
    /// несут смысл, а многоточие вдобавок часто ставит сама модель на оборванной фразе.
    /// Регистр опускаем только у первой буквы предложения; имена, аббревиатуры и намеренный регистр
    /// словаря диктовки защищает `VoiceOutputCase`.
    static func applyOutputOptions(_ text: String, context: VoiceContextDecision? = nil) -> String {
        let s = AppSettings.shared
        let noFinalPeriod = context?.noFinalPeriod ?? s.voiceNoFinalPeriod
        let noCapital = context?.noCapital ?? s.voiceNoCapital
        let noEmDash = context?.noEmDash ?? s.voiceNoEmDash

        var out = text
        if noFinalPeriod, out.hasSuffix("."), !out.hasSuffix("..") {
            out.removeLast()
            out = String(out.reversed().drop { $0 == " " }.reversed())
        }
        if noCapital { out = lowercasedSentenceStarts(out) }
        // Длинные тире → обычный дефис. Меняем и «—», и «–»: на слух они не различаются вовсе, а
        // модель ставит то одно, то другое.
        if noEmDash {
            out = out.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
        }
        return out
    }

    /// Чистая production-логика живёт отдельно и тем же файлом линкуется в VoiceCaseSim. Здесь
    /// остаётся только проводка пользовательского словаря, который знает намеренный регистр слов.
    static func lowercasedSentenceStarts(_ text: String) -> String {
        VoiceOutputCase.lowercasedSentenceStarts(text, keepsCase: VoiceDictionary.shared.keepsCase)
    }

    /// Когда закончилась запись. Нужно только для строки «ожидание=…мс» в логе.
    private var stopStamp: CFAbsoluteTime?

    private func deliver(
        _ text: String,
        historyOnly: Bool = false,
        alreadyCleaned: Bool = false,
        languageHint: String? = nil,
        contextDecision: VoiceContextDecision? = nil,
        audio: String? = nil,
        wave: [UInt8]? = nil
    ) {
        let clean: String
        if alreadyCleaned {
            clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let ghostsCleaned = WhisperGhosts.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = VoiceTextCleaner.clean(
                ghostsCleaned,
                languageHint: languageHint,
                removeFillers: settings.voiceRemoveFillers,
                collapseStutters: settings.voiceCollapseStutters
            )
            clean = VoiceDictionary.shared.apply(normalized)
        }
        // Диктовку отменили по Escape, но человек попросил её всё-таки сохранять (R37). В поле не
        // пишем ничего: Escape означает «не вставляй». Кладём в историю и говорим об этом тостом,
        // иначе сохранение выглядело бы как то, что программа проигнорировала отмену.
        if historyOnly {
            guard !clean.isEmpty else {
                audio.map(VoiceClips.delete)   // текста нет — клипу не к чему прикрепляться
                kbLog("voice: отменённая диктовка пустая — в историю нечего класть"); return
            }
            VoiceHistory.shared.add(clean, audio: audio, wave: wave) { result in
                if result == .saved { VoiceIndicator.shared.showToast(L10n.t("voice.escSaved")) }
                else { VoiceHistory.reportFailure(result) }
            }
            noteVoiceStats(clean)
            return
        }
        guard !clean.isEmpty else {
            audio.map(VoiceClips.delete)   // осиротевший клип: текста, к которому его прикрепить, нет
            kbLog("voice: пустой результат — ничего не вставляю")
            playCue(failSound)   // мягкий нисходящий сигнал «не вышло», чтобы не было тихо
            return
        }
        // Поле пароля/системный диалог украли фокус (инцидент 23.07.2026): печатать нельзя,
        // но распознанное НЕ теряем — история + честный тост вместо молчаливой пропажи.
        if !SecureInputPolicy.canWrite("диктовка \(clean.count) симв.") {
            VoiceHistory.shared.add(clean, audio: audio, wave: wave) { result in
                if result == .saved { VoiceIndicator.shared.showToast(L10n.t("voice.securePwd")) }
                else { VoiceHistory.reportFailure(result) }
            }
            noteVoiceStats(clean)
            return
        }
        // Диагностика «пропадает пунктуация» (10.07): считаем ЗНАКИ ПРЕПИНАНИЯ в выводе (только счётчик,
        // не контент). По логу видно, когда распознавание пришло «сплошняком» (пунктуация=0) — на любом
        // движке. Корень исследован (whisper «no-punctuation mode» / Parakeet не эмитит знак-токены на
        // тихих хвостах). Коррелировать с длительностью/noSpeechMax из строк выше.
        let punct = clean.reduce(0) { $0 + (".,!?;:…—–".contains($1) ? 1 : 0) }
        if let t0 = stopStamp {
            kbLog("voice: ожидание от конца записи до текста \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))мс")
            stopStamp = nil
        }
        kbLog("voice: распознано \(clean.count) симв., пунктуация=\(punct)")
        noteVoiceStats(clean)
        // Пробел в конце — чтобы следующая фраза не слиплась с этой (предложил пользователь).
        // insert — async на serial-очереди; notification шлём в completion (после постинга), чтобы Engine
        // очистил буфер не раньше времени: надиктованный текст не должен попасть в групповую конвертацию (G3).
        // Авто-Enter гасит хвостовой пробел: « текст » + Enter отправляет сообщение с пробелом на
        // конце, и это видно получателю. Настройку пробела при этом НЕ трогаем — человек включит
        // авто-Enter, потом выключит, и его выбор про пробел должен вернуться (тот же принцип, что
        // с громкостями при «Звуки выкл»).
        // Скрытый жест «сказал и отправил» (задача 124): к обычной настройке добавляется разовое
        // намерение, заявленное правым ⌘ в момент окончания диктовки.
        let autoEnter = settings.voiceAutoEnter || sendGestureArmed
        sendGestureArmed = false
        let out = Self.applyOutputOptions(clean, context: contextDecision) + ((settings.voiceTrailingSpace && !autoEnter) ? " " : "")
        // См. второй post ниже по файлу: время НАЧАЛА вставки нужно получателю, чтобы отличить
        // «человек ещё ничего не печатал» от «человек уже набрал слово, пока мы печатали своё».
        let insertT0 = ProcessInfo.processInfo.systemUptime
        TextReplacer.insert(out, thenReturn: autoEnter,
                            returnMods: CGEventFlags(rawValue: settings.voiceAutoEnterMods)) {
            NotificationCenter.default.post(name: .keyboopVoiceInserted, object: nil,
                                            userInfo: ["startedAt": insertT0])
        }
        VoiceHistory.shared.add(clean, audio: audio, wave: wave)
    }

    /// Копим статистику «надиктовано» для счётчика в «О программе». Считаем ТОЛЬКО длину и число слов —
    /// сам текст не сохраняем (принцип №2). Зовётся один раз на удачную вставку: из deliver() (батч)
    /// и с финала стриминга (партиалы не считаем, иначе одна фраза учлась бы многократно).
    private func noteVoiceStats(_ clean: String) {
        settings.voiceChars += clean.count
        settings.voiceWords += clean.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    private var modelIdleRelease: DispatchWorkItem?

    private func loadModelIfNeeded(_ targetId: String? = nil) {
        let modelId = targetId ?? effectiveModelId()
        DispatchQueue.main.async { self.modelIdleRelease?.cancel(); self.modelIdleRelease = nil }
        if engine == nil || loadedModelId != modelId {
            engine = nil
            abortBridgeLock.withLock { abortBridgeRef = nil }
            loadedModelId = ""
            let t0 = ProcessInfo.processInfo.systemUptime
            let path = Self.modelPath(modelId)
            let loaded = TranscribeBridge(modelPath: path)
            engine = loaded
            abortBridgeLock.withLock { abortBridgeRef = loaded }
            if loaded == nil {
                kbLog("voice: модель \(modelId) не загрузилась (\(path))")
            } else {
                loadedModelId = modelId
                kbLog("voice: модель \(modelId) загружена за \(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))мс")
            }
        }
    }

    private func scheduleModelRelease() {
        modelIdleRelease?.cancel(); modelIdleRelease = nil
        if settings.voiceUnloadAfterDictation { releaseModelsNow(); return }
        let minutes = settings.voiceModelIdleMinutes
        guard minutes > 0, engine != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transcribing == 0, !self.isActive, !self.recorder.isRecording else {
                self.scheduleModelRelease(); return
            }
            self.transcribeQueue.async { [weak self] in
                self?.unloadEngineOnQueue()
                kbLog("voice: модель выгружена после \(minutes) мин простоя — память освобождена")
            }
        }
        modelIdleRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * 60, execute: work)
    }

    /// Настройку выгрузки переключили в окне настроек: включили — выгрузить сейчас, выключили —
    /// прогреть модель обратно, как на старте.
    func applyUnloadSetting() {
        if settings.voiceUnloadAfterDictation { releaseModelsNow() } else { preload() }
    }

    private func releaseModelsNow() {
        guard transcribing == 0, !isActive, !recorder.isRecording, !starting,
              !AudioImporter.shared.isRunning, !CallRecorder.shared.isBusy else { return }
        transcribeQueue.async { [weak self] in
            guard let self, self.engine != nil else { return }
            self.unloadEngineOnQueue()
            kbLog("voice: модель выгружена после диктовки (настройка)")
        }
    }

    /// Язык для transcribe.cpp — из настроек. "auto" → авто-определение.
    private func languageForTranscribe() -> String { settings.voiceLanguage }

    // MARK: - Импорт файла (задача 229)

    func transcribeImported(_ samples: [Float]) async -> String? {
        let lang = languageForTranscribe()
        let activeId = effectiveModelId()
        await MainActor.run {
            self.lastVoiceUseAt = Date()
            self.modelIdleRelease?.cancel(); self.modelIdleRelease = nil
        }
        guard await MainActor.run(body: { self.hasUsableModel }) else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            transcribeQueue.async { [weak self] in
                guard let self else { return c.resume(returning: nil) }
                self.loadModelIfNeeded(activeId)
                guard let bridge = self.engine else { return c.resume(returning: nil) }
                c.resume(returning: bridge.transcribe(samples: samples, language: lang))
            }
        }
    }

    /// Импорт закончился: вернуть модели обычный режим выгрузки по простою.
    func importFinished() {
        DispatchQueue.main.async { [weak self] in self?.scheduleModelRelease() }
    }

    /// Синхронно освободить модель ПЕРЕД выходом из процесса (applicationWillTerminate).
    func unloadForTermination() {
        modelIdleRelease?.cancel(); modelIdleRelease = nil
        let sem = DispatchSemaphore(value: 0)
        transcribeQueue.async { [weak self] in
            self?.unloadEngineOnQueue()
            sem.signal()
        }
        if sem.wait(timeout: .now() + 2.0) == .timedOut {
            kbLog("voice: транскрипция висит — выходим, не дожидаясь выгрузки модели")
        }
    }

    // MARK: - Live HUD (нативный стриминг и спекулятивное превью)

    private func unloadEngineOnQueue() {
        engine?.cancelStream()
        engine = nil
        loadedModelId = ""
        abortBridgeLock.withLock { abortBridgeRef = nil }
    }

    private func requestCurrentBridgeAbort() {
        abortBridgeLock.withLock { abortBridgeRef?.requestAbort() }
    }

    private func invalidateLiveSession() {
        liveLock.withLock {
            nativeStreamSessionId = 0
            nativeStreamStarted = false
            nativeStreamSamples.removeAll()
            nativeStreamDrainScheduled = false
            previewSessionId = 0
            previewTailSamples.removeAll()
            previewCommittedPrefix = ""
            previewInFlight = false
            lastLiveHudText = ""
            requestCurrentBridgeAbort()
        }
    }

    private func consumeNativeStreamTrailing() -> (active: Bool, samples: [Float]) {
        liveLock.withLock {
            let active = nativeStreamSessionId != 0
            let trailing = nativeStreamSamples
            nativeStreamSamples.removeAll()
            return (active, trailing)
        }
    }

    private func configureLiveSession(
        sessionToken: Int,
        language: String,
        modelId: String,
        wantStreamingHUD: Bool,
        nativeStreamCapable: Bool
    ) {
        invalidateLiveSession()

        if nativeStreamCapable {
            liveLock.withLock {
                nativeStreamSessionId = sessionToken
                nativeStreamStarted = false
                nativeStreamDrainScheduled = false
            }
            transcribeQueue.async { [weak self] in
                guard let self else { return }
                let stillSame = self.liveLock.withLock { self.nativeStreamSessionId == sessionToken }
                guard stillSame else { return }
                self.loadModelIfNeeded(modelId)
                guard let bridge = self.engine, bridge.supportsStreaming else { return }
                if bridge.beginStream(language: language) {
                    self.liveLock.withLock {
                        if self.nativeStreamSessionId == sessionToken {
                            self.nativeStreamStarted = true
                        }
                    }
                    self.drainNativeStreamOnQueue(sessionId: sessionToken)
                }
            }
            recorder.setChunkHook { [weak self] buf in
                guard let self, !buf.isEmpty else { return }
                let shouldSchedule: Bool = self.liveLock.withLock {
                    guard self.nativeStreamSessionId == sessionToken else { return false }
                    self.nativeStreamSamples.append(contentsOf: buf)
                    if self.nativeStreamStarted,
                       !self.nativeStreamDrainScheduled,
                       self.nativeStreamSamples.count >= 3200 {
                        self.nativeStreamDrainScheduled = true
                        return true
                    }
                    return false
                }
                if shouldSchedule {
                    self.transcribeQueue.async { [weak self] in
                        self?.drainNativeStreamOnQueue(sessionId: sessionToken)
                    }
                }
            }
            return
        }

        if settings.voicePauseChunking {
            var progressCb: LivePauseSession.ProgressCallback?
            if wantStreamingHUD {
                progressCb = { [weak self] assembled in
                    self?.handlePauseProgress(assembled, sessionToken: sessionToken)
                }
            }
            let pSession = LivePauseSession(onProgress: progressCb) { [weak self] pieceSamples async -> String in
                guard let self else { return "" }
                return await self.transcribeWithEngine(samples: pieceSamples, language: language, modelId: modelId)
            }
            self.pauseSession = pSession
            recorder.setPauseChunkHook { [weak pSession] buf in pSession?.append(buf) }
        }

        if wantStreamingHUD {
            liveLock.withLock {
                previewSessionId = sessionToken
                previewTailSamples.removeAll(keepingCapacity: true)
                previewCommittedPrefix = ""
                previewLastAttemptAt = CFAbsoluteTimeGetCurrent()
                previewInFlight = false
            }
            let maxTailSamples = 16_000 * 9
            recorder.setDraftHook { [weak self] buf in
                guard let self, !buf.isEmpty else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let snapshot: [Float]? = self.liveLock.withLock {
                    guard self.previewSessionId == sessionToken else { return nil }
                    self.previewTailSamples.append(contentsOf: buf)
                    if self.previewTailSamples.count > maxTailSamples {
                        self.previewTailSamples.removeFirst(self.previewTailSamples.count - maxTailSamples)
                    }
                    guard !self.previewInFlight,
                          self.previewTailSamples.count >= 16_000,
                          now - self.previewLastAttemptAt >= 1.25 else {
                        return nil
                    }
                    self.previewInFlight = true
                    self.previewLastAttemptAt = now
                    return self.previewTailSamples
                }
                if let snapshot {
                    self.scheduleSpeculativePreviewOnQueue(
                        samples: snapshot,
                        language: language,
                        modelId: modelId,
                        sessionId: sessionToken
                    )
                }
            }
        }
    }

    private func drainNativeStreamOnQueue(sessionId: Int) {
        let batch: [Float] = liveLock.withLock {
            guard nativeStreamSessionId == sessionId else {
                nativeStreamDrainScheduled = false
                return []
            }
            nativeStreamDrainScheduled = false
            let out = nativeStreamSamples
            nativeStreamSamples.removeAll(keepingCapacity: true)
            return out
        }
        guard !batch.isEmpty, let bridge = engine else { return }
        let (rawText, changed) = bridge.feedStream(samples: batch)
        if changed {
            let clean = WhisperGhosts.clean(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                publishLiveHUD(clean, sessionToken: sessionId)
            }
        }
    }

    private func finishNativeStreamOnQueue(
        trailingSamples: [Float],
        fallbackSamples: [Float],
        language: String,
        modelId: String
    ) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            transcribeQueue.async { [weak self] in
                guard let self else { return c.resume(returning: nil) }
                self.loadModelIfNeeded(modelId)
                guard let bridge = self.engine else { return c.resume(returning: nil) }
                if !trailingSamples.isEmpty {
                    _ = bridge.feedStream(samples: trailingSamples)
                }
                if let finalized = bridge.finalizeStream() {
                    return c.resume(returning: finalized)
                }
                c.resume(returning: bridge.transcribe(samples: fallbackSamples, language: language))
            }
        }
    }

    private func cancelNativeStreamOnQueue() {
        transcribeQueue.async { [weak self] in
            self?.engine?.cancelStream()
        }
    }

    private func scheduleSpeculativePreviewOnQueue(
        samples: [Float],
        language: String,
        modelId: String,
        sessionId: Int
    ) {
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.liveLock.withLock {
                    if self.previewSessionId == sessionId {
                        self.previewInFlight = false
                    }
                }
            }
            let activeNow = self.liveLock.withLock { self.previewSessionId == sessionId }
            guard activeNow else { return }
            self.loadModelIfNeeded(modelId)
            guard let bridge = self.engine else { return }
            let canStart: Bool = self.liveLock.withLock {
                guard self.previewSessionId == sessionId else { return false }
                bridge.clearAbort()
                return true
            }
            guard canStart else { return }
            guard let raw = bridge.transcribePreview(samples: samples, language: language) else { return }
            let cleanTail = WhisperGhosts.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTail.isEmpty else { return }

            let composed: String? = self.liveLock.withLock {
                guard self.previewSessionId == sessionId else { return nil }
                if self.previewCommittedPrefix.isEmpty {
                    return cleanTail
                }
                return "\(self.previewCommittedPrefix) \(cleanTail)"
            }
            if let composed {
                self.publishLiveHUD(composed, sessionToken: sessionId)
            }
        }
    }

    private func handlePauseProgress(_ assembled: String, sessionToken: Int) {
        let cleanPrefix = WhisperGhosts.clean(assembled).trimmingCharacters(in: .whitespacesAndNewlines)
        let textToShow: String? = liveLock.withLock {
            guard previewSessionId == sessionToken, !cleanPrefix.isEmpty else { return nil }
            previewCommittedPrefix = cleanPrefix
            previewTailSamples.removeAll(keepingCapacity: true)
            previewLastAttemptAt = CFAbsoluteTimeGetCurrent()
            return cleanPrefix
        }
        if let textToShow {
            publishLiveHUD(textToShow, sessionToken: sessionToken)
        }
    }

    private func publishLiveHUD(_ text: String, sessionToken: Int) {
        let shouldSend = liveLock.withLock { () -> Bool in
            let validSession = (nativeStreamSessionId == sessionToken || previewSessionId == sessionToken)
            guard validSession, text != lastLiveHudText else { return false }
            lastLiveHudText = text
            return true
        }
        guard shouldSend else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingSessionToken == sessionToken, self.recorder.isRecording else { return }
            VoiceIndicator.shared.showLive(text)
        }
    }
}

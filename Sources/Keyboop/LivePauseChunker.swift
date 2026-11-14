import Accelerate
import Foundation

/// Параметры фоновой нарезки длинной диктовки по естественным паузам.
struct LivePausePolicy {
    let sampleRate: Double
    /// Минимальная длительность накопленного буфера до первой автонарезки.
    /// Короткие диктовки (< 10 с) не дробятся и распознаются целиком за один проход.
    let minChunkDuration: Double
    /// Жёсткий потолок одного чанка, если человек говорит без пауз.
    let maxChunkDuration: Double
    /// Длительность тишины для естественного разрыва после minChunkDuration.
    let pauseMinDuration: Double
    /// Порог RMS-громкости кадра тишины.
    let silenceRmsThreshold: Float
    /// Шаг анализа (50 мс = 800 сэмплов на 16 кГц).
    let frameDuration: Double
    /// Окно поиска самого тихого места при достижении maxChunkDuration.
    let hardSplitLookbackSeconds: Double

    static let `default` = LivePausePolicy(
        sampleRate: 16_000,
        minChunkDuration: 10.0,
        maxChunkDuration: 25.0,
        pauseMinDuration: 0.35,
        silenceRmsThreshold: 0.008,
        frameDuration: 0.05,
        hardSplitLookbackSeconds: 4.0
    )

    var frameSamples: Int {
        max(1, Int((sampleRate * frameDuration).rounded()))
    }
}

/// Инкрементальный чанкер для живого микрофонного потока:
/// накапливает аудио во время записи и отдаёт готовые фрагменты на фоновое распознавание
/// на естественных паузах, как только фрагмент становится достаточно длинным.
final class LivePauseChunker {
    let policy: LivePausePolicy

    private var unemittedSamples: [Float] = []
    private var frameRmsHistory: [Float] = []
    private var pendingFrameTail: [Float] = []
    private var emittedCount: Int = 0
    private var emittedSamplesTotal: Int = 0
    private var pendingGapBefore: Double = 0
    private var consecutiveSilentFrames: Int = 0
    private var hasSpeechInChunk = false

    init(policy: LivePausePolicy = .default) {
        self.policy = policy
    }

    var hasEmittedChunks: Bool { emittedCount > 0 }
    var chunkCount: Int { emittedCount }

    /// Добавляет очередной блок 16 кГц PCM и возвращает чанки, готовые к распознаванию прямо сейчас.
    func append(_ samples: [Float]) -> [AudioChunk] {
        guard !samples.isEmpty else { return [] }
        pendingFrameTail.append(contentsOf: samples)

        let frameLen = policy.frameSamples
        let frameDur = policy.frameDuration
        var ready: [AudioChunk] = []

        var offset = 0
        while offset + frameLen <= pendingFrameTail.count {
            var rms: Float = 0
            pendingFrameTail.withUnsafeBufferPointer { buf in
                vDSP_rmsqv(buf.baseAddress! + offset, 1, &rms, vDSP_Length(frameLen))
            }
            let quiet = rms < policy.silenceRmsThreshold

            if !hasSpeechInChunk {
                if quiet {
                    // После уже отданного фрагмента продолжаем копить длительность паузы в gapBefore,
                    // не забивая новый фрагмент и Whisper/Parakeet чистой тишиной.
                    if emittedCount > 0 {
                        pendingGapBefore += frameDur
                    }
                    emittedSamplesTotal += frameLen
                    offset += frameLen
                    continue
                }
                hasSpeechInChunk = true
            }

            let frameSlice = pendingFrameTail[offset..<(offset + frameLen)]
            unemittedSamples.append(contentsOf: frameSlice)
            frameRmsHistory.append(rms)
            if quiet {
                consecutiveSilentFrames += 1
            } else {
                consecutiveSilentFrames = 0
            }
            offset += frameLen

            if let chunk = tryExtractChunkIfNeeded() {
                ready.append(chunk)
            }
        }
        if offset > 0 {
            pendingFrameTail.removeFirst(offset)
        }
        return ready
    }

    /// Возвращает оставшийся хвост аудио при остановке записи (если чанкер уже успел отдать предыдущие части).
    func finishTail() -> AudioChunk? {
        // Добавляем невыровненный остаток кадров только если в фрагменте уже была речь.
        if hasSpeechInChunk && !pendingFrameTail.isEmpty {
            unemittedSamples.append(contentsOf: pendingFrameTail)
        }
        pendingFrameTail.removeAll()
        guard hasSpeechInChunk, !unemittedSamples.isEmpty else {
            unemittedSamples.removeAll()
            frameRmsHistory.removeAll()
            hasSpeechInChunk = false
            consecutiveSilentFrames = 0
            return nil
        }
        let chunk = AudioChunk(
            samples: unemittedSamples,
            startSeconds: Double(emittedSamplesTotal) / policy.sampleRate,
            gapBefore: pendingGapBefore
        )
        emittedSamplesTotal += unemittedSamples.count
        unemittedSamples.removeAll()
        frameRmsHistory.removeAll()
        consecutiveSilentFrames = 0
        hasSpeechInChunk = false
        pendingGapBefore = 0
        emittedCount += 1
        return chunk
    }

    private func tryExtractChunkIfNeeded() -> AudioChunk? {
        let currentFrames = frameRmsHistory.count
        let frameDur = policy.frameDuration
        let unemittedDur = Double(currentFrames) * frameDur

        guard unemittedDur >= policy.minChunkDuration else { return nil }

        let requiredSilentFrames = max(1, Int((policy.pauseMinDuration / frameDur).rounded()))
        if consecutiveSilentFrames >= requiredSilentFrames {
            // Режем по середине паузы: первую половину оставляем в хвосте уходящего чанка,
            // а остаток тишины до следующей речи считаем в pendingGapBefore (см. append).
            let silentSplit = max(1, currentFrames - (consecutiveSilentFrames / 2))
            let tailDroppedFrames = currentFrames - silentSplit
            let pauseDuration = Double(consecutiveSilentFrames) * frameDur
            let chunk = sliceChunk(upToFrame: silentSplit, nextGap: pauseDuration, dropRemainingTail: true)
            emittedSamplesTotal += tailDroppedFrames * policy.frameSamples
            consecutiveSilentFrames = 0
            hasSpeechInChunk = false
            return chunk
        }

        if unemittedDur >= policy.maxChunkDuration {
            let lookbackFrames = max(1, Int((policy.hardSplitLookbackSeconds / frameDur).rounded()))
            let searchStart = max(1, currentFrames - lookbackFrames)
            var bestFrame = currentFrames
            var bestRms = Float.greatestFiniteMagnitude
            for idx in searchStart..<currentFrames where frameRmsHistory[idx] < bestRms {
                bestRms = frameRmsHistory[idx]
                bestFrame = idx
            }
            let chunk = sliceChunk(upToFrame: bestFrame, nextGap: 0, dropRemainingTail: false)
            consecutiveSilentFrames = countTrailingSilentFrames(in: frameRmsHistory)
            hasSpeechInChunk = frameRmsHistory.contains { $0 >= policy.silenceRmsThreshold }
            return chunk
        }

        return nil
    }

    private func sliceChunk(upToFrame splitFrame: Int, nextGap: Double, dropRemainingTail: Bool) -> AudioChunk? {
        let frameLen = policy.frameSamples
        let splitSample = min(unemittedSamples.count, splitFrame * frameLen)
        guard splitSample > 0 else { return nil }

        let samples = Array(unemittedSamples[..<splitSample])
        let startSeconds = Double(emittedSamplesTotal) / policy.sampleRate
        let chunk = AudioChunk(
            samples: samples,
            startSeconds: startSeconds,
            gapBefore: pendingGapBefore
        )

        if dropRemainingTail {
            unemittedSamples.removeAll(keepingCapacity: true)
            frameRmsHistory.removeAll(keepingCapacity: true)
        } else {
            unemittedSamples.removeFirst(splitSample)
            let removedFrames = min(frameRmsHistory.count, splitFrame)
            frameRmsHistory.removeFirst(removedFrames)
        }
        emittedSamplesTotal += splitSample
        emittedCount += 1
        pendingGapBefore = nextGap
        return chunk
    }

    private func countTrailingSilentFrames(in frames: [Float]) -> Int {
        var count = 0
        for rms in frames.reversed() {
            if rms < policy.silenceRmsThreshold {
                count += 1
            } else {
                break
            }
        }
        return count
    }
}

/// Управляет фоновой последовательной транскрибацией чанков во время долгой диктовки.
/// Гарантирует строгий FIFO-порядок распознавания (модели Whisper/Parakeet не thread-safe для параллельного вызова).
final class LivePauseSession: @unchecked Sendable {
    typealias Transcriber = @Sendable ([Float]) async -> String
    typealias ProgressCallback = @Sendable (String) -> Void

    private struct WorkItem {
        let chunk: AudioChunk
    }

    private let chunker: LivePauseChunker
    private let transcriber: Transcriber
    private let onProgress: ProgressCallback?
    private let lock = NSLock()
    private let chunkQueue = DispatchQueue(label: "keyboop.voice.pausechunk", qos: .utility)

    private var queue: [WorkItem] = []
    private var pieces: [TranscriptAssembler.Piece] = []
    private var workerRunning = false
    private var cancelled = false
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    init(policy: LivePausePolicy = .default,
         onProgress: ProgressCallback? = nil,
         transcriber: @escaping Transcriber) {
        self.chunker = LivePauseChunker(policy: policy)
        self.onProgress = onProgress
        self.transcriber = transcriber
    }

    var hasEmittedChunks: Bool {
        lock.withLock { chunker.hasEmittedChunks }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        chunkQueue.async { [weak self] in
            guard let self else { return }
            let isCancelled = self.lock.withLock { self.cancelled }
            guard !isCancelled else { return }

            let ready = self.lock.withLock { () -> [AudioChunk] in
                guard !self.cancelled else { return [] }
                return self.chunker.append(samples)
            }
            if !ready.isEmpty {
                self.enqueue(ready)
            }
        }
    }

    func cancel() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancelled = true
            queue.removeAll()
            let w = finishedWaiters
            finishedWaiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume() }
    }

    /// Дожидается завершения чанкинга и транскрибации всех фрагментов.
    /// Возвращает `nil`, если за время записи не сработал ни один промежуточный срез
    /// (в этом случае вызывающий код идёт по стандартному single-shot пути).
    func finishAndAssemble() async -> String? {
        // Сначала дожидаемся разбора всех буферов на chunkQueue.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            chunkQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                let tail = self.lock.withLock { () -> AudioChunk? in
                    guard !self.cancelled, self.chunker.hasEmittedChunks else { return nil }
                    return self.chunker.finishTail()
                }
                if let tail {
                    self.enqueue([tail])
                }
                cont.resume()
            }
        }

        let usedChunking = lock.withLock { chunker.hasEmittedChunks && !cancelled }
        guard usedChunking else { return nil }

        await waitUntilIdle()

        let resultPieces = lock.withLock { () -> [TranscriptAssembler.Piece]? in
            guard !cancelled else { return nil }
            return pieces
        }
        guard let resultPieces else { return nil }

        return TranscriptAssembler.join(resultPieces)
    }

    private func enqueue(_ chunks: [AudioChunk]) {
        var shouldStartWorker = false
        lock.withLock {
            guard !cancelled else { return }
            for c in chunks {
                queue.append(WorkItem(chunk: c))
            }
            if !workerRunning {
                workerRunning = true
                shouldStartWorker = true
            }
        }
        if shouldStartWorker {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.drainWorker()
            }
        }
    }

    private func drainWorker() async {
        while true {
            let next: WorkItem? = lock.withLock {
                if cancelled || queue.isEmpty {
                    workerRunning = false
                    return nil
                }
                return queue.removeFirst()
            }

            guard let item = next else {
                let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    let w = finishedWaiters
                    finishedWaiters.removeAll()
                    return w
                }
                waiters.forEach { $0.resume() }
                return
            }

            let rawText = await transcriber(item.chunk.samples)
            let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot: String? = lock.withLock {
                if !cancelled && !cleaned.isEmpty {
                    pieces.append(TranscriptAssembler.Piece(text: cleaned, gapBefore: item.chunk.gapBefore))
                    return TranscriptAssembler.join(pieces)
                }
                return nil
            }
            if let snapshot, !snapshot.isEmpty {
                onProgress?(snapshot)
            }
        }
    }

    private func waitUntilIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if cancelled || (!workerRunning && queue.isEmpty) {
                    cont.resume()
                } else {
                    finishedWaiters.append(cont)
                }
            }
        }
    }
}

import Foundation

final class WordCompletionRequest {
    enum WriteResult { case skipped, confirmed, unconfirmed }

    private let lock = NSLock()
    private var cancelled = false
    private var inference: URLSessionDataTask?

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        let task = lock.withLock {
            cancelled = true
            let task = inference
            inference = nil
            return task
        }
        task?.cancel()
    }

    func startInference(_ task: URLSessionDataTask) {
        lock.withLock {
            guard !cancelled else { task.cancel(); return }
            inference = task
            task.resume()
        }
    }

    func insert<T>(readTarget: () -> T?, write: (T) -> Bool, verify: () -> Bool) -> WriteResult {
        guard !isCancelled, let target = readTarget(), !isCancelled else { return .skipped }
        // AX timeouts can occur after an edit was applied. Attempt the write at most once.
        guard write(target), !isCancelled, verify(), !isCancelled else { return .unconfirmed }
        return .confirmed
    }
}

import Darwin
import Foundation
import MachO

enum PredictionUsage {
    enum Language: String, CaseIterable {
        case ru, en

        init?(suggestion: String) {
            for scalar in suggestion.unicodeScalars {
                switch scalar.value {
                case 0x410...0x44F, 0x401, 0x451: self = .ru; return
                case 65...90, 97...122: self = .en; return
                default: continue
                }
            }
            return nil
        }

        // A numeric date can be the entire suggestion. Use its nearest preceding word.
        static func infer(from suggestion: String, after before: String) -> Language? {
            Language(suggestion: suggestion) ?? Language(suggestion: String(before.reversed()))
        }
    }

    enum Event {
        case shown(latencyMS: Double?)
        case accepted(saved: Int)
        case undone(saved: Int)
    }

    struct Counts: Codable, Equatable {
        var shown = 0
        var accepted = 0
        var undone = 0
        var saved = 0
        var timed = 0
        var totalMS = 0.0
        var acceptancePercent: Double? { shown > 0 ? 100 * Double(accepted) / Double(shown) : nil }
        var meanMS: Double? { timed > 0 ? totalMS / Double(timed) : nil }

        mutating func record(_ event: Event) {
            switch event {
            case let .shown(latency):
                shown += 1
                if let latency, latency.isFinite, latency >= 0 {
                    totalMS += latency
                    timed += 1
                }
            case let .accepted(keys):
                accepted += 1
                saved += keys
            case let .undone(keys):
                undone += 1
                saved -= keys
            }
        }
    }

    struct Build: Codable {
        let id: String
        let version: String
        var ru = Counts()
        var en = Counts()

        subscript(_ language: Language) -> Counts {
            get { language == .ru ? ru : en }
            set { if language == .ru { ru = newValue } else { en = newValue } }
        }

        static let current: Build = {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            // The linker UUID distinguishes development builds that share a version number.
            if let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 {
                var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
                for _ in 0..<header.pointee.ncmds {
                    let load = command.load(as: load_command.self)
                    if load.cmd == LC_UUID {
                        let uuid = command.load(as: uuid_command.self).uuid
                        return Build(id: UUID(uuid: uuid).uuidString, version: version)
                    }
                    command = command.advanced(by: Int(load.cmdsize))
                }
            }
            return Build(id: version, version: version)
        }()
    }

    static let undoWindow: TimeInterval = 2

    // A shortcut invocation costs one action, the same unit used by the replay benchmark.
    static func savedKeys(for insertion: String) -> Int { max(0, insertion.count - 1) }
}

final class PredictionUsageStore {
    static let changed = Notification.Name("KeyboopPredictionUsageChanged")
    static let shared = PredictionUsageStore(directory: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Keyboop", isDirectory: true))
    static let filename = "prediction-usage-v1.json"
    let directory: URL
    let build: PredictionUsage.Build
    private let queue = DispatchQueue(label: "ru.keyboop.prediction-usage", qos: .utility)

    init(directory: URL, build: PredictionUsage.Build = .current) {
        self.directory = directory
        self.build = build
    }

    static func read(_ url: URL) throws -> [PredictionUsage.Build] {
        do {
            return try JSONDecoder().decode([PredictionUsage.Build].self, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
    }

    func load(_ completion: @escaping (Result<[PredictionUsage.Build], Error>) -> Void) {
        queue.async {
            let result = Result { try Self.read(self.directory.appendingPathComponent(Self.filename)) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func record(_ event: PredictionUsage.Event, language: PredictionUsage.Language) {
        queue.async {
            do {
                try self.write(event, language: language)
            } catch {
                NSLog("Keyboop: could not update prediction usage (%ld)", (error as NSError).code)
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
        }
    }

    // Dev and release may run concurrently. The lock covers the complete read/modify/rename.
    private func write(_ event: PredictionUsage.Event, language: PredictionUsage.Language) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent(".prediction-usage.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let url = directory.appendingPathComponent(Self.filename)
        var builds = try Self.read(url)
        let index = builds.firstIndex { $0.id == build.id }
        var entry = index.map { builds.remove(at: $0) } ?? build
        entry[language].record(event)
        builds.insert(entry, at: 0)
        try JSONEncoder().encode(builds).write(to: url, options: .atomic)
    }
}

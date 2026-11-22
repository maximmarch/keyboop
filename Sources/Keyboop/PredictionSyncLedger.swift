import CryptoKit
import Foundation

/// One register per word or setting. A deletion keeps its revision and a digest of the key.
struct PredictionSyncLedger: Codable, Equatable {
    struct Revision: Codable, Comparable {
        let clock: Int64
        let writer: UUID

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.clock == rhs.clock ? lhs.writer.uuidString < rhs.writer.uuidString : lhs.clock < rhs.clock
        }
    }

    struct Entry<Value: Codable & Equatable>: Codable, Equatable {
        let revision: Revision
        let value: Value
    }

    static let optionKeys = ["wordCompletionEnabled", "nextWordEnabled", "predictionInfillEnabled",
                             "predictionFieldWordsEnabled", "predictionSystemSpellingEnabled"]
    var version = 1
    var words: [String: Entry<String?>] = [:]
    var options: [String: Entry<Bool>] = [:]

    static func key(_ word: String) -> String {
        let normalized = word.precomposedStringWithCanonicalMapping
        let hex = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: Data(normalized.utf8)).flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func terms(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            if !word.isEmpty { result[key(word)] = word }
        }
        return result
    }

    var activeWords: [String: String] { words.compactMapValues { $0.value } }

    // Preserve additions received while the glossary editor was open.
    static func editedGlossary(original: String, edited: String, current: String) -> String {
        guard current != original else { return edited }
        let old = terms(original), edits = terms(edited)
        var result = terms(current)
        for key in Set(old.keys).union(edits.keys) where old[key] != edits[key] { result[key] = edits[key] }
        return result.values.sorted().joined(separator: "\n")
    }

    func validate() throws {
        guard version == 1, options.keys.allSatisfy(Self.optionKeys.contains),
              words.allSatisfy({ key, entry in
                  key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                      && entry.value.map { !$0.isEmpty && !$0.contains(where: \.isNewline) && Self.key($0) == key } != false
              }), (Array(words.values.map(\.revision)) + options.values.map(\.revision)).allSatisfy({
                  $0.clock > 0 && $0.clock < Int64.max - 1
              }) else { throw CocoaError(.fileReadCorruptFile) }
    }

    mutating func merge(_ other: Self) {
        words.merge(other.words) { $0.revision < $1.revision ? $1 : $0 }
        options.merge(other.options) { $0.revision < $1.revision ? $1 : $0 }
    }

    static func reconcile(previous: Self?, peers: [Self], glossary: [String: String],
                          preferences: [String: Bool], writer: UUID) -> Self {
        var result = previous ?? Self()
        for peer in peers { result.merge(peer) }
        let clock = max(result.words.values.map(\.revision.clock).max() ?? 0,
                        result.options.values.map(\.revision.clock).max() ?? 0)
        let revision = Revision(clock: clock + 1, writer: writer)
        let old = previous?.activeWords ?? [:]
        for key in Set(glossary.keys).union(old.keys) where glossary[key] != old[key] {
            // On first pairing the remote history also knows about previously deleted words.
            if previous != nil || result.words[key] == nil {
                result.words[key] = Entry(revision: revision, value: glossary[key])
            }
        }
        for key in optionKeys {
            let value = preferences[key] ?? false
            let changed = previous.map { value != ($0.options[key]?.value ?? false) } ?? (value && result.options[key] == nil)
            if changed {
                result.options[key] = Entry(revision: revision, value: value)
            }
        }
        return result
    }
}

/// Each installation owns its files. Cloud providers can deliver two offline edits in either order.
struct PredictionSyncFolder {
    let directory: URL
    let writer: UUID
    private let fm = FileManager.default
    private let coordinated: Bool

    init(root: URL, writer: UUID) throws {
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
        guard info.isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        directory = root.lastPathComponent == "Keyboop Sync" ? root : root.appendingPathComponent("Keyboop Sync", isDirectory: true)
        self.writer = writer
        let components = root.standardizedFileURL.pathComponents
        coordinated = info.isUbiquitousItem == true || zip(components, components.dropFirst()).contains {
            $0 == "Library" && ($1 == "Mobile Documents" || $1 == "CloudStorage")
        }
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw error }
        }
    }

    func files(suffix: String) throws -> [URL] {
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [URL] = []
        for url in urls {
            var name = url.lastPathComponent
            let placeholder = name.hasPrefix(".") && name.hasSuffix(".icloud")
            if placeholder { name = String(name.dropFirst().dropLast(".icloud".count)) }
            guard name.hasSuffix(suffix), UUID(uuidString: String(name.dropLast(suffix.count))) != nil else { continue }
            if placeholder {
                try fm.startDownloadingUbiquitousItem(at: directory.appendingPathComponent(name))
                throw CocoaError(.fileReadUnknown)
            }
            result.append(url)
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func own(_ suffix: String) -> URL { directory.appendingPathComponent(writer.uuidString + suffix) }

    func read(_ url: URL, limit: Int) throws -> Data {
        func load(_ item: URL) throws -> Data {
            let info = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                         .ubiquitousItemDownloadingStatusKey])
            if info.ubiquitousItemDownloadingStatus == .notDownloaded {
                try fm.startDownloadingUbiquitousItem(at: item)
                throw CocoaError(.fileReadUnknown)
            }
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= limit else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: item)
            guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
            return data
        }
        // Ordinary and network folders use single-writer files and atomic rename.
        guard coordinated else { return try load(url) }
        var coordination: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { item in
            result = Result { try load(item) }
        }
        if let coordination { throw coordination }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    func write(_ data: Data?, to url: URL, allowed: () -> Bool) throws {
        func save(_ item: URL) throws {
            guard allowed() else { return }
            if let data { try data.write(to: item, options: .atomic) }
            else if fm.fileExists(atPath: item.path) { try fm.removeItem(at: item) }
        }
        guard coordinated else { return try save(url) }
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: data == nil ? .forDeleting : .forReplacing,
                                       error: &coordination) { item in
            do { try save(item) } catch { failure = error }
        }
        if let error = failure ?? coordination { throw error }
    }
}

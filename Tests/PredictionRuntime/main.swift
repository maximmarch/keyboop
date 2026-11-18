import Foundation

// The state-machine suite runs as a separate executable without the AppKit app or a network.
// Its child provides the normal early-exit failure instead of loading weights.
if CommandLine.arguments.dropFirst().first == "--prediction-server-supervisor" { exit(1) }

enum L10n { static func t(_ key: String) -> String { key } }
enum ModelDownloader {
    static func sha256(ofFileAt url: URL) -> String? { nil } // no remote downloads in this suite
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let suite = "KeyboopTests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let manager = PredictionRuntime(defaults: defaults, directory: temp)
precondition(!manager.usesExternalServer && !manager.hasSelectedModel)
precondition(manager.selectedModelID == "qwen3-0.6b-base")
precondition(manager.connection() == nil)
manager.setEnabled(true)
precondition(manager.statusText.hasSuffix("missing") && manager.connection() == nil)
manager.usesExternalServer = true
precondition(manager.connection()?.baseURL.absoluteString == "http://127.0.0.1:18181")
manager.setEnabled(false)
precondition(manager.connection() == nil)
manager.usesExternalServer = false
let second = PredictionRuntime.models[1]
manager.selectedModelID = second.id
precondition(manager.selectedModelID == second.id)
precondition(manager.statusText.hasSuffix("disabled"))
let url = temp.appendingPathComponent(second.filename)
precondition(FileManager.default.createFile(atPath: url.path, contents: nil))
let file = try FileHandle(forWritingTo: url)
try file.truncate(atOffset: UInt64(second.bytes))
try file.close()
precondition(manager.hasSelectedModel)
manager.setEnabled(true)
let timeout = Date().addingTimeInterval(5)
while manager.statusText.contains("starting") && Date() < timeout { Thread.sleep(forTimeInterval: 0.05) }
precondition(manager.connection() == nil)
precondition(["startFailed", "exited", "serverMissing"].contains(where: manager.statusText.contains))
manager.deleteSelected()
precondition(!manager.hasSelectedModel && manager.statusText.hasSuffix("missing"))
manager.shutdown()
precondition(manager.connection() == nil)

defaults.set(true, forKey: "predictiveLocalModelEnabled")
let reopened = PredictionRuntime(defaults: defaults, directory: temp)
precondition(!reopened.usesExternalServer && reopened.selectedModelID == second.id)
defaults.set("retired-model", forKey: "predictionModelID")
let fallback = PredictionRuntime(defaults: defaults, directory: temp)
precondition(!fallback.usesExternalServer && fallback.selectedModelID == "qwen3-0.6b-base")
defaults.set(second.id, forKey: "predictionModelID")

// Previously enabled users keep the external backend, without starting a second llama process.
defaults.removeObject(forKey: "predictionExternalServer")
let migrated = PredictionRuntime(defaults: defaults, directory: temp)
migrated.setEnabled(true)
precondition(migrated.usesExternalServer && migrated.selectedModelID == second.id)
precondition(migrated.connection()?.apiKey == nil)
migrated.shutdown()

// The same pipe EOF happens when the GUI is killed. The supervisor must reap only its owned child.
let pipe = Pipe()
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sleep")
child.arguments = ["8"]
DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
    try? pipe.fileHandleForWriting.close()
}
let start = ProcessInfo.processInfo.systemUptime
let exitStatus = try PredictionRuntime.supervise(child, owner: pipe.fileHandleForReading)
precondition(exitStatus != 0 && !child.isRunning && ProcessInfo.processInfo.systemUptime - start < 4)
print("Prediction runtime: model defaults, saved selection, migration, startup failure, deletion, shutdown and parent-pipe ownership passed")


let rightNeighbors = Set(["plan", "details"])
precondition(PredictionRuntime.infillProbeVerdict(.finished("Plan"), expected: rightNeighbors) == .ready)
precondition(PredictionRuntime.infillProbeVerdict(.finished("tomorrow"), expected: rightNeighbors) == .unsuitable)
precondition(PredictionRuntime.infillProbeVerdict(.finished(nil), expected: rightNeighbors) == .unsuitable)
precondition(PredictionRuntime.infillProbeVerdict(.failed("prediction.unavailable"), expected: rightNeighbors) == .unavailable)
migrated.setInfillEnabled(true)
precondition(migrated.infillConnection() == nil && migrated.infillStatus == .unavailable)
print("Infill requires the bundled runner and a passing quality probe")

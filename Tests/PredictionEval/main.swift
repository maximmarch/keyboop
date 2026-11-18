import Foundation

func number(_ n: Double?) -> String {
    n.map { String(format: "%.1f", $0) } ?? "-"
}

func milliseconds(_ n: Double?) -> String {
    n.map { String(format: "%.3f", $0) } ?? "-"
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    var baseURL: URL?
    var tracesURL: URL?
    var completionCandidates: [URL] = []
    if args.isEmpty || args == ["--dictionary"] {
        baseURL = nil
    } else if args.count == 2, args[0] == "--port", let port = Int(args[1]), (1...65535).contains(port) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")
    } else if args.count >= 3, args[0] == "--compare-completion" {
        tracesURL = URL(fileURLWithPath: args[1])
        completionCandidates = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
    } else {
        throw NSError(domain: "KeyboopEvaluation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected --dictionary, --port <number>, or --compare-completion <traces.json> <candidate.json>..."
        ])
    }
    print("mode\tgroup\tcases\tshown\thit_%\tprecision_%\twrong_shows\tpotential_saved_keys\tfirst_p50_ms\tfirst_p95_ms\tmodeled_key_p95_ms\tinterrupted\terrors\tlookup_p95_ms")
    let resources = URL(fileURLWithPath: "Sources/Keyboop/Resources")
    _ = try PredictionComparison().compare(resources: resources, baseURL: baseURL,
                                           apiKey: ProcessInfo.processInfo.environment["KEYBOOP_EVAL_API_KEY"],
                                           tracesURL: tracesURL, completionCandidates: completionCandidates) { summaries in
        for s in summaries {
            let recall = 100 * Double(s.correct) / Double(s.cases)
            let precision = s.shown > 0 ? 100 * Double(s.correct) / Double(s.shown) : nil
            print([s.mode, s.group, String(s.cases), String(s.shown), number(recall), number(precision),
                   String(s.shown - s.correct), String(s.savedKeys), milliseconds(s.firstP50MS), milliseconds(s.firstP95MS),
                   milliseconds(s.modeledKeyP95MS), String(s.interrupted), String(s.errors),
                   milliseconds(s.lookupP95MS)].joined(separator: "\t"))
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

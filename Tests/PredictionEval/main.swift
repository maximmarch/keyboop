import Foundation

func number(_ n: Double?) -> String {
    n.map { String(format: "%.1f", $0) } ?? "-"
}

func milliseconds(_ n: Double?) -> String {
    n.map { String(format: "%.3f", $0) } ?? "-"
}

do {
    enum Mode: String { case pipeline = "--pipeline", compare = "--compare-completion", confidence = "--tune-confidence" }
    var args = Array(CommandLine.arguments.dropFirst())
    let mode = args.first.flatMap(Mode.init(rawValue:))
    if mode != nil { args.removeFirst() }
    var baseURL: URL?
    var tracesURL: URL?
    var completionCandidates: [URL] = []
    var pipelineCandidate: URL?
    var infillTraces: URL?
    var holdout: URL?
    var confidence: PredictiveLocalModel.Confidence = .qwen3
    let usage = "Expected --dictionary, --port <number>, --pipeline [--port <number>] [--completion-data <candidate.json>] [--infill <traces.json>], "
        + "--compare-completion <traces.json> <candidate.json>..., or --tune-confidence <holdout.json> --port <number> [--completion-data <candidate.json>]. Model runs accept --confidence <qwen3|baseline>."
    func invalidArguments() -> NSError {
        NSError(domain: "KeyboopEvaluation", code: 1, userInfo: [NSLocalizedDescriptionKey: usage])
    }
    if mode == .compare {
        guard args.count >= 2 else { throw invalidArguments() }
        tracesURL = URL(fileURLWithPath: args[0])
        completionCandidates = args.dropFirst().map { URL(fileURLWithPath: $0) }
    } else {
        if mode == .confidence {
            guard let path = args.first, !path.hasPrefix("--") else { throw invalidArguments() }
            holdout = URL(fileURLWithPath: path)
            args.removeFirst()
        } else if mode == nil, args == ["--dictionary"] {
            args = []
        }
        var options = Set<String>()
        var remaining = args[...]
        while let option = remaining.popFirst() {
            guard options.insert(option).inserted, let value = remaining.popFirst(), !value.hasPrefix("--") else {
                throw invalidArguments()
            }
            switch option {
            case "--port":
                guard let port = Int(value), (1...65535).contains(port) else { throw invalidArguments() }
                baseURL = URL(string: "http://127.0.0.1:\(port)")
            case "--infill" where mode == .pipeline:
                infillTraces = URL(fileURLWithPath: value)
            case "--completion-data" where mode == .pipeline || mode == .confidence:
                pipelineCandidate = URL(fileURLWithPath: value)
            case "--confidence" where mode != .confidence && (value == "qwen3" || value == "baseline"):
                confidence = value == "qwen3" ? .qwen3 : .baseline
            default:
                throw invalidArguments()
            }
        }
        if mode == .confidence && baseURL == nil { throw invalidArguments() }
    }
    let header = "mode\tgroup\tcases\tshown\thit_%\tprecision_%\twrong_shows\tpotential_saved_keys\tfirst_p50_ms\tfirst_p95_ms\tmodeled_key_p95_ms\tinterrupted\terrors\tlookup_p95_ms"
    let sourceHeader = "\tnegative_cases\tnegative_shows\tmisses\tdictionary_shows\tmodel_shows\thistory_shows\tmodel_p95_ms"
    let includeSourceMetrics = mode != nil
    print(includeSourceMetrics ? header + sourceHeader : header)
    let resources = URL(fileURLWithPath: "Sources/Keyboop/Resources")
    let edges = URL(fileURLWithPath: "Tests/PredictionEval/pipeline_traces.json")
    let apiKey = ProcessInfo.processInfo.environment["KEYBOOP_EVAL_API_KEY"]
    func report(_ summaries: [PredictionComparison.Summary]) {
        for s in summaries {
            let recall = s.cases > 0 ? 100 * Double(s.correct) / Double(s.cases) : nil
            let precision = s.shown > 0 ? 100 * Double(s.correct) / Double(s.shown) : nil
            var values = [s.mode, s.group, String(s.cases), String(s.shown), number(recall), number(precision),
                          String(s.shown - s.correct), String(s.savedKeys), milliseconds(s.firstP50MS),
                          milliseconds(s.firstP95MS), milliseconds(s.modeledKeyP95MS), String(s.interrupted),
                          String(s.errors), milliseconds(s.lookupP95MS)]
            if includeSourceMetrics {
                values += [String(s.negativeCases), String(s.negativeShows), String(s.misses),
                           String(s.dictionaryShows), String(s.modelShows), String(s.historyShows), milliseconds(s.modelP95MS)]
            }
            print(values.joined(separator: "\t"))
        }
    }
    let comparison = PredictionComparison()
    if let holdout, let baseURL {
        try comparison.compareConfidence(resources: resources, edgesURL: edges, holdoutURL: holdout, baseURL: baseURL,
                                         apiKey: apiKey, completionData: pipelineCandidate, report: report)
    } else if mode == .pipeline {
        try comparison.comparePipeline(resources: resources, edgesURL: edges, baseURL: baseURL, apiKey: apiKey,
                                       completionData: pipelineCandidate, confidence: confidence, report: report)
        if let infillTraces {
            try comparison.compareInfill(tracesURL: infillTraces, baseURL: baseURL, apiKey: apiKey, report: report)
        }
    } else {
        _ = try comparison.compare(resources: resources, baseURL: baseURL, apiKey: apiKey,
                                   tracesURL: tracesURL, completionCandidates: completionCandidates,
                                   confidence: confidence, report: report)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

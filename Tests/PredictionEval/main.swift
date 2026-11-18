import Foundation

func number(_ n: Double?) -> String {
    n.map { String(format: "%.1f", $0) } ?? "-"
}

func milliseconds(_ n: Double?) -> String {
    n.map { String(format: "%.3f", $0) } ?? "-"
}

do {
    let pipeline = CommandLine.arguments.dropFirst().first == "--pipeline"
    let args = Array(CommandLine.arguments.dropFirst(pipeline ? 2 : 1))
    var baseURL: URL?
    var tracesURL: URL?
    var completionCandidates: [URL] = []
    if args.isEmpty || (!pipeline && args == ["--dictionary"]) {
        baseURL = nil
    } else if args.count == 2, args[0] == "--port", let port = Int(args[1]), (1...65535).contains(port) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")
    } else if !pipeline, args.count >= 3, args[0] == "--compare-completion" {
        tracesURL = URL(fileURLWithPath: args[1])
        completionCandidates = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
    } else {
        throw NSError(domain: "KeyboopEvaluation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected --dictionary, --port <number>, --pipeline [--port <number>], or --compare-completion <traces.json> <candidate.json>..."
        ])
    }
    let header = "mode\tgroup\tcases\tshown\thit_%\tprecision_%\twrong_shows\tpotential_saved_keys\tfirst_p50_ms\tfirst_p95_ms\tmodeled_key_p95_ms\tinterrupted\terrors\tlookup_p95_ms"
    let pipelineHeader = "\tnegative_cases\tnegative_shows\tmisses\tdictionary_shows\tmodel_shows\thistory_shows\tmodel_p95_ms"
    print(pipeline ? header + pipelineHeader : header)
    let resources = URL(fileURLWithPath: "Sources/Keyboop/Resources")
    let apiKey = ProcessInfo.processInfo.environment["KEYBOOP_EVAL_API_KEY"]
    func report(_ summaries: [PredictionComparison.Summary]) {
        for s in summaries {
            let recall = s.cases > 0 ? 100 * Double(s.correct) / Double(s.cases) : nil
            let precision = s.shown > 0 ? 100 * Double(s.correct) / Double(s.shown) : nil
            var values = [s.mode, s.group, String(s.cases), String(s.shown), number(recall), number(precision),
                          String(s.shown - s.correct), String(s.savedKeys), milliseconds(s.firstP50MS),
                          milliseconds(s.firstP95MS), milliseconds(s.modeledKeyP95MS), String(s.interrupted),
                          String(s.errors), milliseconds(s.lookupP95MS)]
            if pipeline {
                values += [String(s.negativeCases), String(s.negativeShows), String(s.misses),
                           String(s.dictionaryShows), String(s.modelShows), String(s.historyShows), milliseconds(s.modelP95MS)]
            }
            print(values.joined(separator: "\t"))
        }
    }
    let comparison = PredictionComparison()
    if pipeline {
        let edges = URL(fileURLWithPath: "Tests/PredictionEval/pipeline_traces.json")
        try comparison.comparePipeline(resources: resources, edgesURL: edges, baseURL: baseURL, apiKey: apiKey, report: report)
    } else {
        _ = try comparison.compare(resources: resources, baseURL: baseURL, apiKey: apiKey,
                                   tracesURL: tracesURL, completionCandidates: completionCandidates, report: report)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

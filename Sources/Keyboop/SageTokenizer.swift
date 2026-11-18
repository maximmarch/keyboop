import Foundation

/// GPT-2 byte-pair tokenizer for the pinned SAGE FRED-T5 Distilled 95M weights.
struct SageTokenizer {
    static let encoderBeginToken: Int64 = 50_357  // <LM>, separate from the model config's <s>
    static let decoderStartToken: Int64 = 0
    static let endToken: Int64 = 2
    static let maximumInputTokens = 512
    static let maximumOutputTokens = 768
    static let maximumInputBytes = 8192

    enum Failure: Error {
        case invalidVocabulary
        case invalidMerges
        case inputTooLong
        case invalidOutput
    }

    private struct Pair: Hashable {
        let left: String
        let right: String

        var merged: String { left + right }
    }

    // ByteLevel splits the model's UTF-8 input with the original GPT-2 regular expression.
    // In particular, the optional leading space is ASCII and contractions are case-sensitive.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
    )

    private static let alphabet: [Unicode.Scalar] = {
        var extended: UInt32 = 256
        return (0...255).map { byte in
            if (33...126).contains(byte) || (161...172).contains(byte) || (174...255).contains(byte) {
                return Unicode.Scalar(byte)!
            }
            defer { extended += 1 }
            return Unicode.Scalar(extended)!
        }
    }()
    private static let bytesBySymbol = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { (index, scalar) in
        (scalar, UInt8(index))
    })

    private let tokenIDs: [String: Int64]
    private let tokensByID: [Int64: String]
    private let ranks: [Pair: Int]

    init(vocabulary: URL, merges: URL) throws {
        let ids = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: vocabulary))
        guard Self.alphabet.allSatisfy({ ids[String($0)] != nil }) else { throw Failure.invalidVocabulary }
        var tokens: [Int64: String] = [:]
        tokens.reserveCapacity(ids.count)
        for (text, id) in ids {
            guard id >= 0, tokens.updateValue(text, forKey: id) == nil else { throw Failure.invalidVocabulary }
        }

        let rules = try String(contentsOf: merges, encoding: .utf8)
        var ranks: [Pair: Int] = [:]
        for (index, line) in rules.split(whereSeparator: \.isNewline).enumerated() {
            if index == 0 && line.hasPrefix("#version:") { continue }
            let symbols = line.split(separator: " ")
            guard symbols.count == 2 else { throw Failure.invalidMerges }
            let pair = Pair(left: String(symbols[0]), right: String(symbols[1]))
            guard ids[pair.merged] != nil, ranks.updateValue(index, forKey: pair) == nil else {
                throw Failure.invalidMerges
            }
        }

        tokenIDs = ids
        tokensByID = tokens
        self.ranks = ranks
    }

    func encode(_ text: String) throws -> [Int64] {
        guard text.utf8.count <= Self.maximumInputBytes else { throw Failure.inputTooLong }
        let source = text as NSString
        let matchRange = NSRange(location: 0, length: source.length)
        var result: [Int64] = [Self.encoderBeginToken]
        var cachedIDs: [String: [Int64]] = [:]
        for match in Self.tokenPattern.matches(in: text, range: matchRange) {
            let piece = source.substring(with: match.range)
            let mappedBytes = piece.utf8.map { String(Self.alphabet[Int($0)]) }
            // Key the cache on byte symbols so canonically equivalent Unicode strings stay distinct.
            let key = mappedBytes.joined()
            let ids: [Int64]
            if let cached = cachedIDs[key] {
                ids = cached
            } else {
                ids = try merge(mappedBytes).map { symbol in
                    guard let id = tokenIDs[symbol] else { throw Failure.invalidVocabulary }
                    return id
                }
                cachedIDs[key] = ids
            }
            guard result.count + ids.count <= Self.maximumInputTokens else { throw Failure.inputTooLong }
            result.append(contentsOf: ids)
        }
        // FRED-T5 adds the encoder prefix but no EOS to a single input.
        return result
    }

    private func merge(_ bytes: [String]) -> [String] {
        var symbols = bytes
        while symbols.count > 1 {
            var bestPair: Pair?
            var bestRank = Int.max
            for index in 1..<symbols.count {
                let pair = Pair(left: symbols[index - 1], right: symbols[index])
                if let rank = ranks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = pair
                }
            }
            guard let bestPair else { break }

            var merged: [String] = []
            var index = 0
            while index < symbols.count {
                if index + 1 < symbols.count, symbols[index] == bestPair.left, symbols[index + 1] == bestPair.right {
                    merged.append(bestPair.merged)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        return symbols
    }

    func decode(_ ids: [Int64]) throws -> String {
        guard ids.count <= Self.maximumOutputTokens else { throw Failure.invalidOutput }
        var result: [UInt8] = []
        for id in ids {
            // Model control tokens include sentinels and <LM>/<SCn> above the base vocabulary.
            if (0...4).contains(id) || (50_257...50_363).contains(id) { continue }
            guard let token = tokensByID[id] else { throw Failure.invalidOutput }
            for symbol in token.unicodeScalars {
                guard let byte = Self.bytesBySymbol[symbol] else { throw Failure.invalidOutput }
                result.append(byte)
            }
        }
        guard let text = String(bytes: result, encoding: .utf8) else { throw Failure.invalidOutput }
        return text
    }
}

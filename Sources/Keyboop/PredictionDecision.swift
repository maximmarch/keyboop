import Foundation

/// Text-only routing shared by live predictions and evaluation. AX checks and network work stay with the caller.
enum PredictionDecision {
    static let debounceMS = 120
    static let modelBudgetMS = 650

    enum Trigger {
        case completion(useContext: Bool)
        case nextWord
    }

    enum Suppression: String {
        case rightText = "prediction.rightText"
        case noMatch = "prediction.noMatch"
        case spellcheck = "prediction.spellcheck"
    }

    enum Choice: Equatable {
        case skip(Suppression)
        case dictionary(prefix: String, suffix: String)
        case reference(prefix: String, suffix: String, source: PredictionReferenceIndex.Source)
        case personal(prefix: String, suffix: String)
        case model(before: String, prefix: String, contextWord: String)
    }

    static func resolve(before rawBefore: String, after: String, startsAtFieldStart: Bool,
                        endsAtFieldEnd: Bool = true, trigger: Trigger,
                        index: @autoclosure () -> WordCompletionIndex,
                        next: @autoclosure () -> NextWordIndex?,
                        references: @autoclosure () -> PredictionReferenceIndex? = nil,
                        useFieldReferences: Bool = false,
                        personal: @autoclosure () -> PersonalPredictionHistory? = nil) -> Choice {
        guard after.isEmpty || after.first?.isNewline == true else { return .skip(.rightText) }
        let before = rawBefore.replacingOccurrences(of: "\u{00A0}", with: " ")
        switch trigger {
        case let .completion(useContext):
            guard let prefix = WordCompletionIndex.prefix(before: before, after: after,
                                                           startsAtFieldStart: startsAtFieldStart),
                  prefix.count >= 3 else { return .skip(.noMatch) }
            if let references = references(), useFieldReferences || !references.isEmpty {
                if PredictionReferenceIndex.isInsideCode(before) { return .skip(.noMatch) }
                switch references.lookup(prefix: prefix, before: before, after: after, startsAtFieldStart: startsAtFieldStart,
                                         endsAtFieldEnd: endsAtFieldEnd, useField: useFieldReferences) {
                case .finishedWord:
                    return .skip(.noMatch)
                case let .suggestion(suffix, source):
                    guard !index().contains(prefix) else { return .skip(.noMatch) }
                    return .reference(prefix: prefix, suffix: suffix, source: source)
                case .noMatch:
                    break
                }
            }
            let preceding = String(before.dropLast(prefix.count))
            if let personal = personal(), !PredictionReferenceIndex.isInsideCode(before) {
                let context = useContext ? PersonalPredictionObservation.context(before: preceding,
                                                                                 startsAtFieldStart: startsAtFieldStart) : []
                if let suffix = personal.completion(for: prefix, after: context), !index().contains(prefix) {
                    return .personal(prefix: prefix, suffix: suffix)
                }
            }
            let preferred = useContext ? next()?.predict(before: preceding,
                                                         startsAtFieldStart: startsAtFieldStart) : nil
            if let suffix = index().suffix(for: prefix, preferredWord: preferred) {
                return .dictionary(prefix: prefix, suffix: suffix)
            }
            return .model(before: before, prefix: prefix, contextWord: prefix)
        case .nextWord:
            if before.last == " ", before.dropLast().last?.isWhitespace == false,
               let personal = personal(), !PredictionReferenceIndex.isInsideCode(before) {
                let context = PersonalPredictionObservation.context(before: before, startsAtFieldStart: startsAtFieldStart)
                if let word = personal.nextWord(after: context) { return .personal(prefix: "", suffix: word) }
            }
            if let suffix = next()?.predict(before: before, startsAtFieldStart: startsAtFieldStart) {
                return .dictionary(prefix: "", suffix: suffix)
            }
            guard before.last == " ",
                  let word = WordCompletionIndex.prefix(before: String(before.dropLast()), after: "",
                                                        startsAtFieldStart: startsAtFieldStart) else { return .skip(.noMatch) }
            return .model(before: before, prefix: "", contextWord: word)
        }
    }
}

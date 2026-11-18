import AppKit
import ApplicationServices
import Carbon

final class WordCompletion {
    typealias Trigger = PredictionDecision.Trigger

    private struct Field {
        let element: AXUIElement
        let pid: pid_t
        let position: Int
        let length: Int
        let before: String
        let after: String
        let startsAtFieldStart: Bool
        let endsAtFieldEnd: Bool
        let geometry: CaretLocator.Geometry
        var bounds: CGRect { geometry.rect }
        let viewport: CGRect?

        func matches(_ other: Field) -> Bool {
            pid == other.pid && position == other.position
                && startsAtFieldStart == other.startsAtFieldStart && endsAtFieldEnd == other.endsAtFieldEnd
                && before.utf16.elementsEqual(other.before.utf16) && after.utf16.elementsEqual(other.after.utf16)
                && CFEqual(element, other.element)
        }

        func matchesInfill(_ other: Field) -> Bool {
            length == other.length && matches(other)
        }

        func hasSameLayout(as other: Field) -> Bool {
            bounds == other.bounds && viewport == other.viewport && geometry.font == other.geometry.font
        }
    }

    private struct Suggestion {
        var field: Field
        let trigger: Trigger
        let prefix: String
        let suffix: String
        let inputSource: String
    }

    enum Insertion {
        case confirmed(prefix: String, suffix: String)
        case confirmedInfill
        case unconfirmed
    }

    private let worker = DispatchQueue(label: "ru.keyboop.word-completion", qos: .userInitiated)
    private lazy var localModel = PredictiveLocalModel()
    private var glossaryIndex = (text: "", index: PredictionReferenceIndex(glossary: ""))
    // Worker-only identity for the field receiving consecutive model requests.
    private var inferenceContext: (pid: pid_t, element: AXUIElement, source: String, id: UUID)?
    private lazy var index: WordCompletionIndex = {
        let words = LayoutData.shared.wordsRu.union(LayoutData.shared.wordsEn)
        if let resources = Bundle.main.resourceURL, let index = try? CompletionVocabulary.index(words: words, resources: resources) {
            return index
        }
        return WordCompletionIndex(words: words)
    }()
    private lazy var nextWordIndex: NextWordIndex? = {
        guard let url = Bundle.main.url(forResource: "next_words", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NextWordIndex.self, from: data)
    }()
    // State owned by main. The worker only sees each request's cancellation flag.
    private var request: WordCompletionRequest?
    private var debounce: DispatchWorkItem?
    private var suggestion: Suggestion?
    private struct TypedTail {
        let original: Suggestion
        var typed: String
    }
    private var deferredAccept: (() -> Void)?
    private var pendingTail: TypedTail?
    private var keySeed: TypedTail?
    private var overlay: NSPanel?
    var hasSuggestion: Bool { suggestion != nil || pendingTail != nil }

    private struct PersonalAnchor {
        let field: Field
        let session: UInt64
    }
    private(set) var personalLearningEnabled = false
    private var learning = PendingPredictionLearning<PersonalAnchor>()
    private var learningEpoch: UInt64 = 0
    private var didPassPersonalKey = false
    private var manuallyTyped = ""
    private var manualBoundary: UInt64 = 0
    private var personalForward = ""

    func invalidate() {
        clearRequest()
        keySeed = nil
        if overlay?.isVisible == true { overlay?.orderOut(nil) }
    }

    func resetInferenceContext() {
        invalidate()
        cancelPersonalLearningContext()
        worker.async { [weak self] in self?.inferenceContext = nil }
    }

    func configurePersonalLearning(_ enabled: Bool) {
        guard enabled != personalLearningEnabled else { return }
        personalLearningEnabled = enabled
        PersonalPredictionStore.shared.setEnabled(enabled)
        resetInferenceContext()
    }

    func cancelPersonalLearningContext() {
        learningEpoch &+= 1
        learning.cancel()
        manuallyTyped = ""
        personalForward = ""
    }

    private func cacheScope(for field: Field, source: String) -> UUID {
        if let context = inferenceContext, context.pid == field.pid, context.source == source,
           CFEqual(context.element, field.element) { return context.id }
        let id = UUID()
        inferenceContext = (field.pid, field.element, source, id)
        return id
    }

    private func clearRequest() {
        request?.cancel()
        request = nil
        debounce?.cancel()
        debounce = nil
        suggestion = nil
        pendingTail = nil
        deferredAccept = nil
    }

    // The event tap calls these around a physical key. Only input that survives all hotkeys,
    // layout fixes and snippet handling reaches continueTyping.
    func beginKeyDown() {
        didPassPersonalKey = false
        keySeed = pendingTail ?? suggestion.map { TypedTail(original: $0, typed: "") }
        clearRequest()
    }

    func endKeyDown() {
        if personalLearningEnabled && !didPassPersonalKey { cancelPersonalLearningContext() }
        keySeed = nil
        if suggestion == nil && pendingTail == nil && overlay?.isVisible == true { overlay?.orderOut(nil) }
    }

    // Called only for letters and a plain space that the engine lets through to the editor.
    func observePersonalInput(_ text: String, isEligible: @escaping () -> Bool) {
        guard personalLearningEnabled else { return }
        didPassPersonalKey = true
        let boundary = text == " "
        let typedWord = boundary ? manuallyTyped : ""
        if boundary {
            manuallyTyped = ""
            manualBoundary &+= 1
        } else if manuallyTyped.count <= 32 {
            manuallyTyped.append(text)
        }

        let pending = learning.pending
        guard pending != nil || (2...32).contains(typedWord.count) else { return }
        if pending != nil {
            personalForward += text
            if personalForward.utf16.count > 128 {
                learning.cancel()
                personalForward = ""
            }
        }
        let appended = personalForward
        let epoch = learningEpoch
        let boundaryNumber = manualBoundary
        // Allow the editor to process the physical key and the existing boundary corrections.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(boundary ? 80 : 20)) { [weak self] in
            guard let self, self.learningEpoch == epoch, isEligible(),
                  let session = PersonalPredictionStore.shared.session,
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            let verifiesPending = pending?.anchor.session == session && !appended.isEmpty &&
                self.learning.pending?.observation.id == pending?.observation.id && self.personalForward == appended
            let checksWord = (2...32).contains(typedWord.count) && self.manualBoundary == boundaryNumber
            let laterTyping = checksWord ? self.manuallyTyped : ""
            guard verifiesPending || checksWord else { return }
            self.worker.async { [weak self] in
                let current = Self.readField(pid: pid)
                let forwardConfirmed = verifiesPending && Self.matchesPersonalAdvance(from: pending?.anchor.field,
                                                                                        to: current, text: appended)
                let word = current.flatMap { field -> PersonalPredictionObservation? in
                    guard checksWord, field.after.isEmpty || field.after.first?.isNewline == true else { return nil }
                    return PersonalPredictionObservation.manual(typedWord, in: field.before,
                                                                 startsAtFieldStart: field.startsAtFieldStart,
                                                                 followedBy: laterTyping)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.learningEpoch == epoch, isEligible() else { return }
                    if verifiesPending, let pending, self.personalForward == appended,
                       self.learning.pending?.observation.id == pending.observation.id {
                        self.personalForward = ""
                        if let accepted = self.learning.advance(pending.observation.id, verified: forwardConfirmed) {
                            self.savePersonalObservation(accepted, session: session)
                        }
                    }
                    if let word, self.manualBoundary == boundaryNumber { self.savePersonalObservation(word, session: session) }
                }
            }
        }
    }

    private static func matchesPersonalAdvance(from anchor: Field?, to current: Field?, text: String) -> Bool {
        guard let anchor, let current, anchor.pid == current.pid, CFEqual(anchor.element, current.element) else { return false }
        return PredictionPhrase.matchesEdit(before: anchor.before, after: anchor.after, inserted: text,
                                            position: anchor.position, newBefore: current.before, newAfter: current.after,
                                            newPosition: current.position)
    }

    private func savePersonalObservation(_ observation: PersonalPredictionObservation, session: UInt64) {
        worker.async { PersonalPredictionStore.shared.record(observation, session: session) }
    }

    func continueTyping(_ characters: String, isEligible: @escaping (Trigger) -> Bool) -> Bool {
        guard var tail = keySeed, !tail.original.trigger.isInfill, !characters.isEmpty,
              isEligible(tail.original.trigger) else { return false }
        tail.typed += characters
        guard tail.original.suffix.hasPrefix(tail.typed) else { return false }
        keySeed = nil
        if tail.original.suffix == tail.typed {
            invalidate()
            return false
        }
        pendingTail = tail
        let current = WordCompletionRequest()
        request = current
        let expected = tail
        worker.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
            let remainder = String(expected.original.suffix.dropFirst(expected.typed.count))
            let next = Self.readAdvanced(expected.original, inserted: expected.typed, remainder: remainder, request: current)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request === current else { return }
                self.pendingTail = nil
                let accept = self.deferredAccept
                self.deferredAccept = nil
                guard let next, self.present(next, request: current, isEligible: { isEligible(next.trigger) }) else {
                    self.invalidate()
                    return
                }
                accept?()
            }
        }
        return true
    }

    private func present(_ candidate: Suggestion, request: WordCompletionRequest, isEligible: @escaping () -> Bool) -> Bool {
        guard isEligible(), Self.keyboardLayoutID() == candidate.inputSource,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.field.pid else {
            PredictionDiagnostic.shared.record("prediction.changed")
            return false
        }
        let first = suggestion == nil
        guard show(candidate) else {
            PredictionDiagnostic.shared.record("prediction.noRoom")
            return false
        }
        suggestion = candidate
        if first { watch(candidate, request: request, until: .now() + .seconds(6), isEligible: isEligible) }
        return true
    }

    func schedule(_ trigger: Trigger, useLocalModel: Bool, useInfill: Bool,
                  isEligible: @escaping (Trigger) -> Bool) {
        invalidate()
        let request = WordCompletionRequest()
        self.request = request
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.request === request else { return }
            self.debounce = nil
            guard isEligible(trigger), let source = Self.keyboardLayoutID(),
                  let app = NSWorkspace.shared.frontmostApplication else {
                PredictionDiagnostic.shared.record("prediction.ineligible")
                self.invalidate()
                return
            }
            let pid = app.processIdentifier
            let references = AppSettings.shared.predictionReferencePreferences
            let usePersonal = self.personalLearningEnabled
            let useSystemSpelling = AppSettings.shared.predictionSystemSpellingEnabled
            self.worker.async { [weak self] in
                guard let self, !request.isCancelled else { return }
                self.makeSuggestion(pid: pid, trigger: trigger, source: source, request: request,
                                    useLocalModel: useLocalModel, useInfill: useInfill, references: references,
                                    usePersonal: usePersonal, useSystemSpelling: useSystemSpelling) { [weak self] candidate, reason in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request === request else { return }
                        guard let candidate else {
                            // A deadline may follow an already displayed, complete word.
                            if self.suggestion != nil && reason == "prediction.timeout" { return }
                            PredictionDiagnostic.shared.record(reason)
                            self.invalidate()
                            return
                        }
                        if let visible = self.suggestion, visible.suffix == candidate.suffix,
                           visible.field.hasSameLayout(as: candidate.field) { return }
                        guard self.present(candidate, request: request, isEligible: { isEligible(candidate.trigger) }) else {
                            self.invalidate()
                            return
                        }
                        PredictionDiagnostic.shared.record(reason, geometry: candidate.field.geometry.source.rawValue)
                    }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(PredictionDecision.debounceMS), execute: work)
    }

    // Freeze the displayed phrase before touching the field. Late streaming updates and watchers
    // from its original request cannot replace the tail while an accepted word is being inserted.
    func accept(isEligible: @escaping (Trigger) -> Bool, finished: @escaping (Insertion) -> Void) -> Bool {
        if let pendingTail, isEligible(pendingTail.original.trigger),
           Self.keyboardLayoutID() == pendingTail.original.inputSource {
            // The old overlay is still visible while the host applies the typed letter.
            // Retain this explicit accept until its new AX position has been verified.
            deferredAccept = { [weak self] in _ = self?.accept(isEligible: isEligible, finished: finished) }
            return true
        }
        guard let candidate = suggestion, isEligible(candidate.trigger),
              Self.keyboardLayoutID() == candidate.inputSource else { return false }
        if candidate.trigger.isInfill { return acceptInfill(candidate, finished: finished) }
        guard let accepted = PredictionPhrase.acceptFirstWord(candidate.suffix) else { return false }
        invalidate()
        let current = WordCompletionRequest()
        request = current
        let learn = personalLearningEnabled
        let epoch = learningEpoch
        worker.async { [weak self] in
            let session = learn ? PersonalPredictionStore.shared.session : nil
            let result = Self.insert(candidate, chunk: accepted.insertion, request: current)
            var next: Suggestion?
            if case .confirmed = result?.insertion, !accepted.remainder.isEmpty {
                next = Self.readAdvanced(candidate, inserted: accepted.insertion, remainder: accepted.remainder, request: current)
            }
            let observation = session.flatMap { _ in
                result?.field.flatMap { field in
                    let word = candidate.prefix + accepted.insertion.trimmingCharacters(in: .whitespaces)
                    return PersonalPredictionObservation.manual(word, in: field.before, startsAtFieldStart: field.startsAtFieldStart)
                }
            }
            let tail = next
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let valid = self.request === current && isEligible(candidate.trigger)
                if self.learningEpoch == epoch, learn {
                    if valid, let observation, let session, let newField = result?.field,
                       PersonalPredictionStore.shared.session == session {
                        let anchor = PersonalAnchor(field: newField, session: session)
                        if let last = self.learning.accepted(observation, at: anchor, follows: {
                            $0.session == session && $0.field.matches(candidate.field)
                        }) { self.savePersonalObservation(last, session: session) }
                        self.manuallyTyped = ""
                        self.personalForward = ""
                    } else {
                        self.cancelPersonalLearningContext()
                    }
                }
                if self.request === current {
                    if let tail, valid {
                        if !self.present(tail, request: current, isEligible: { isEligible(candidate.trigger) }) { self.invalidate() }
                    } else {
                        self.invalidate()
                    }
                }
                if let result { finished(valid ? result.insertion : .unconfirmed) }
            }
        }
        return true
    }

    private func makeSuggestion(pid: pid_t, trigger: Trigger, source: String, request: WordCompletionRequest,
                                useLocalModel: Bool, useInfill: Bool, references: PredictionReferenceIndex.Preferences,
                                usePersonal: Bool, useSystemSpelling: Bool,
                                finished: @escaping (Suggestion?, String) -> Void) {
        if trigger.isInfill {
            makeInfillSuggestion(pid: pid, source: source, request: request, finished: finished)
            return
        }
        var fieldReason = "prediction.field"
        guard let field = Self.readField(pid: pid, report: { fieldReason = $0 }) else {
            finished(nil, fieldReason)
            return
        }
        guard !request.isCancelled else { return }
        if case .nextWord = trigger, useInfill, let first = field.after.first, !first.isNewline {
            makeInfillSuggestion(pid: pid, source: source, request: request, finished: finished)
            return
        }
        let choice = PredictionDecision.resolve(before: field.before, after: field.after,
                                                startsAtFieldStart: field.startsAtFieldStart,
                                                endsAtFieldEnd: field.endsAtFieldEnd, trigger: trigger,
                                                index: index, next: nextWordIndex,
                                                references: referenceIndex(for: references),
                                                useFieldReferences: references.useField,
                                                personal: usePersonal ? PersonalPredictionStore.shared.snapshot() : nil)
        func deliver(_ choice: PredictionDecision.Choice) {
            guard !request.isCancelled else { return }
            finishSuggestion(choice, field: field, trigger: trigger, source: source, request: request,
                             useLocalModel: useLocalModel, finished: finished)
        }

        if case .model = choice, !useLocalModel {
            deliver(choice)
            return
        }
        guard useSystemSpelling,
              let query = choice.systemQuery(before: field.before, startsAtFieldStart: field.startsAtFieldStart),
              query.mode != .previous || !index.contains(query.word) else {
            deliver(choice)
            return
        }
        SystemWordRecognizer.shared.recognize(query, replyOn: worker, isCancelled: { request.isCancelled }) { finding in
            deliver(query.gate(choice, finding: finding))
        }
    }

    private func makeInfillSuggestion(pid: pid_t, source: String, request: WordCompletionRequest,
                                      finished: @escaping (Suggestion?, String) -> Void) {
        guard !request.isCancelled, !IsSecureEventInputEnabled() else { return }
        guard let endpoint = PredictionRuntime.shared.infillConnection(), let key = endpoint.apiKey else {
            finished(nil, PredictionRuntime.shared.infillStatus.messageKey)
            return
        }
        guard let field = Self.readField(pid: pid, rightLimit: PredictionPhrase.InfillContext.rightLimit),
              let context = Self.infillContext(field), !request.isCancelled else {
            finished(nil, "prediction.rightText")
            return
        }
        let deadline = DispatchTime.now() + .milliseconds(PredictionDecision.modelBudgetMS)
        localModel.infill(context, endpoint: endpoint.baseURL, apiKey: key,
                          cacheScope: cacheScope(for: field, source: source), request: request, deadline: deadline) { [weak self] event in
            self?.worker.async {
                guard !request.isCancelled else { return }
                guard DispatchTime.now() < deadline else { finished(nil, "prediction.timeout"); return }
                switch event {
                case .finished(let word):
                    guard let word else { finished(nil, "prediction.lowConfidence"); return }
                    guard let current = Self.readField(pid: pid, rightLimit: PredictionPhrase.InfillContext.rightLimit),
                          field.matchesInfill(current),
                          Self.infillContext(current)?.edit(for: word) != nil, !request.isCancelled else {
                        finished(nil, "prediction.changed")
                        return
                    }
                    guard DispatchTime.now() < deadline else { finished(nil, "prediction.timeout"); return }
                    finished(Suggestion(field: current, trigger: .infill, prefix: "", suffix: word, inputSource: source),
                             "prediction.infill")
                case .failed(let reason): finished(nil, reason)
                case .partial: break
                }
            }
        }
    }

    private static func infillContext(_ field: Field) -> PredictionPhrase.InfillContext? {
        PredictionPhrase.InfillContext(before: field.before, after: field.after, endsAtFieldEnd: field.endsAtFieldEnd)
    }

    private func acceptInfill(_ candidate: Suggestion, finished: @escaping (Insertion) -> Void) -> Bool {
        guard let edit = Self.infillContext(candidate.field)?.edit(for: candidate.suffix) else { return false }
        invalidate()
        let current = WordCompletionRequest()
        request = current
        worker.async { [weak self] in
            let result = Self.insertInfill(candidate, edit: edit, request: current)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request === current else { return }
                self.invalidate()
                self.cancelPersonalLearningContext()
                finished(result)
            }
        }
        return true
    }

    private func finishSuggestion(_ choice: PredictionDecision.Choice, field: Field, trigger: Trigger, source: String,
                                  request: WordCompletionRequest, useLocalModel: Bool,
                                  finished: @escaping (Suggestion?, String) -> Void) {
        let pid = field.pid
        func publish(_ suffix: String, prefix: String, reason: String) {
            guard !request.isCancelled else { return }
            guard let current = Self.readField(pid: pid), field.matches(current) else {
                finished(nil, "prediction.changed")
                return
            }
            finished(Suggestion(field: current, trigger: trigger, prefix: prefix, suffix: suffix, inputSource: source), reason)
        }
        let before, prefix, contextWord: String
        switch choice {
        case let .skip(reason):
            finished(nil, reason.rawValue)
            return
        case let .dictionary(prefix, suffix):
            publish(suffix, prefix: prefix, reason: "prediction.dictionary")
            return
        case let .reference(prefix, suffix, origin):
            publish(suffix, prefix: prefix, reason: origin.rawValue)
            return
        case let .personal(prefix, suffix):
            publish(suffix, prefix: prefix, reason: "prediction.personal")
            return
        case let .model(text, stem, word):
            guard useLocalModel else { finished(nil, "prediction.noMatch"); return }
            (before, prefix, contextWord) = (text, stem, word)
        }
        guard !request.isCancelled, !IsSecureEventInputEnabled(),
              let current = Self.readField(pid: pid), field.matches(current) else {
            finished(nil, "prediction.changed")
            return
        }
        guard let connection = PredictionRuntime.shared.connection() else { finished(nil, "prediction.modelNotReady"); return }
        // Only the managed server has our private single slot and no shared prompt cache.
        let scope = connection.apiKey.map { _ in cacheScope(for: current, source: source) }
        let context = scope == nil ? before : PredictiveLocalModel.stableContext(before, caretPosition: current.position)
        // Give a warm model its own budget after the dictionary pass; new input still cancels immediately.
        let deadline = DispatchTime.now() + .milliseconds(PredictionDecision.modelBudgetMS)
        localModel.predict(before: context, contextWord: contextWord, completing: !prefix.isEmpty,
                           endpoint: connection.baseURL, apiKey: connection.apiKey, cacheScope: scope,
                           request: request, deadline: deadline, confidence: .forModel(connection.modelID)) { [weak self] event in
            self?.worker.async {
                guard !request.isCancelled else { return }
                switch event {
                case .partial(let text), .finished(.some(let text)):
                    guard DispatchTime.now() <= deadline else { finished(nil, "prediction.timeout"); return }
                    publish(text, prefix: prefix, reason: "prediction.model")
                case .failed(let reason): finished(nil, reason)
                case .finished(nil): finished(nil, "prediction.noMatch")
                }
            }
        }
    }

    // Runs on the prediction worker, after the request passes the same context guards as other sources.
    private func referenceIndex(for preferences: PredictionReferenceIndex.Preferences) -> PredictionReferenceIndex? {
        if glossaryIndex.text != preferences.glossary {
            glossaryIndex = (preferences.glossary, PredictionReferenceIndex(glossary: preferences.glossary))
        }
        return preferences.useField || !glossaryIndex.index.isEmpty ? glossaryIndex.index : nil
    }

    private static func readAdvanced(_ candidate: Suggestion, inserted: String, remainder: String,
                                     request: WordCompletionRequest) -> Suggestion? {
        let target = candidate.field
        for attempt in 0..<4 {
            guard !request.isCancelled else { return nil }
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.015) }
            guard let field = readField(pid: target.pid), CFEqual(target.element, field.element) else { return nil }
            if PredictionPhrase.matchesEdit(before: target.before, after: target.after, inserted: inserted, position: target.position,
                                            newBefore: field.before, newAfter: field.after, newPosition: field.position) {
                let prefix = field.before.reversed().prefix(while: { $0.isLetter }).reversed()
                return Suggestion(field: field, trigger: candidate.trigger, prefix: String(prefix),
                                  suffix: remainder, inputSource: candidate.inputSource)
            }
        }
        return nil
    }

    private func watch(_ candidate: Suggestion, request: WordCompletionRequest, until expiry: DispatchTime,
                       isEligible: @escaping () -> Bool) {
        // Reflow, scrolling and a growing composer can move the same insertion point between
        // AX reads. Keep the latest streamed suffix and place it at the current coordinates.
        worker.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard !request.isCancelled else { return }
            let rightLimit = candidate.trigger.isInfill ? PredictionPhrase.InfillContext.rightLimit : 12
            let current = DispatchTime.now() < expiry ? Self.readField(pid: candidate.field.pid, rightLimit: rightLimit) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request === request, var visible = self.suggestion else { return }
                guard let current, visible.field.matches(current), isEligible(),
                      !visible.trigger.isInfill || visible.field.length == current.length else { self.invalidate(); return }
                if !visible.field.hasSameLayout(as: current) {
                    visible.field = current
                    guard self.present(visible, request: request, isEligible: isEligible) else {
                        self.invalidate()
                        return
                    }
                }
                self.watch(visible, request: request, until: expiry, isEligible: isEligible)
            }
        }
    }

    private static func insert(_ suggestion: Suggestion, chunk: String,
                               request: WordCompletionRequest) -> (insertion: Insertion, field: Field?)? {
        let target = suggestion.field
        var validated: Field?
        let result = request.insert(readTarget: { () -> Field? in
            guard let current = readField(pid: target.pid),
                  target.matches(current), !IsSecureEventInputEnabled() else { return nil }
            return current
        }, write: { field in
            TextReplacer.postSuggestion(chunk, to: field.pid)
        }, verify: {
            // The target processes a posted keystroke asynchronously. Only reread the field.
            for attempt in 0..<5 {
                guard !request.isCancelled else { return false }
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.02) }
                guard let updated = readField(pid: target.pid),
                      CFEqual(updated.element, target.element) else { return false }
                guard updated.position == target.position + chunk.utf16.count else { continue }
                guard PredictionPhrase.matchesEdit(before: target.before, after: target.after, inserted: chunk,
                                                    position: target.position, newBefore: updated.before,
                                                    newAfter: updated.after, newPosition: updated.position) else { return false }
                validated = updated
                return true
            }
            return false
        })
        switch result {
        case .skipped: return nil
        case .unconfirmed: return (.unconfirmed, nil)
        case .confirmed: return (.confirmed(prefix: suggestion.prefix, suffix: chunk), validated)
        }
    }

    private static func insertInfill(_ suggestion: Suggestion, edit: PredictionPhrase.InfillEdit,
                                     request: WordCompletionRequest) -> Insertion {
        let target = suggestion.field
        let rightLimit = PredictionPhrase.InfillContext.rightLimit
        func read() -> Field? { readField(pid: target.pid, rightLimit: rightLimit) }
        func verify(advanced: Bool) -> Field? {
            let expectedPosition = target.position + edit.insertion.utf16.count
                + (advanced ? edit.borrowedSpace.utf16.count : 0)
            for attempt in 0..<5 {
                guard !request.isCancelled else { return nil }
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.02) }
                guard let updated = read(), CFEqual(updated.element, target.element) else { return nil }
                if updated.position != expectedPosition { continue }
                guard updated.length == target.length + edit.insertion.utf16.count,
                      edit.verifies(before: target.before, after: target.after, position: target.position,
                                    newBefore: updated.before, newAfter: updated.after, newPosition: updated.position,
                                    advanced: advanced) else { return nil }
                return updated
            }
            return nil
        }
        let result = request.insert(readTarget: { () -> Field? in
            guard let field = read(), target.matchesInfill(field),
                  infillContext(field)?.edit(for: edit.word) == edit else { return nil }
            return field
        }, write: { field in
            TextReplacer.postSuggestion(edit.insertion, to: field.pid)
        }, verify: {
            guard let written = verify(advanced: false) else { return false }
            guard !edit.borrowedSpace.isEmpty else { return true }
            guard !request.isCancelled, let latest = read(), written.matchesInfill(latest),
                  !request.isCancelled else { return false }
            let next = latest.position + edit.borrowedSpace.utf16.count
            guard advanceCaret(in: latest, to: next, request: request) else { return false }
            return verify(advanced: true) != nil
        })
        return result == .confirmed ? .confirmedInfill : .unconfirmed
    }

    private static func advanceCaret(in field: Field, to position: Int, request: WordCompletionRequest) -> Bool {
        var writable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(field.element, kAXSelectedTextRangeAttribute as CFString, &writable)
        guard !request.isCancelled, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == field.pid else { return false }
        if result == .success, writable.boolValue {
            var range = CFRange(location: position, length: 0)
            guard let selection = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(field.element, kAXSelectedTextRangeAttribute as CFString, selection) == .success
        }
        // Marker-only editors can accept the same single right arrow as an ordinary keyboard event.
        return TextReplacer.postSuggestionRightArrow(to: field.pid)
    }

    private static func readField(pid: pid_t, rightLimit: Int = 12, report: (String) -> Void = { _ in }) -> Field? {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        let focused: CFTypeRef?
        if let systemFocus = attribute(system, kAXFocusedUIElementAttribute) {
            focused = systemFocus
        } else {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            focused = attribute(app, kAXFocusedUIElementAttribute)
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard isEditableText(element) else { return nil }
        return snapshot(element: element, pid: pid, rightLimit: rightLimit, report: report)
    }

    private static func isEditableText(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let secureRole = kAXSecureTextFieldSubrole as String
        guard role != secureRole, subrole != secureRole,
              attribute(element, kAXEnabledAttribute) as? Bool != false else { return false }

        // Web editors and some custom controls declare editability directly.
        let editable = (attribute(element, "AXIsEditable") as? Bool) ?? (attribute(element, "AXEditable") as? Bool)
        if let editable { return editable }

        // Native text controls normally advertise writable text through their AX setters.
        guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
                || role == kAXComboBoxRole as String || role == kAXGroupRole as String else { return false }
        return [kAXSelectedTextAttribute, kAXValueAttribute].contains { name in
            var writable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
        }
    }

    private static func snapshot(element: AXUIElement, pid: pid_t, rightLimit: Int, report: (String) -> Void) -> Field? {
        var range = CFRange()
        guard let selected = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID(),
              AXValueGetValue(selected as! AXValue, .cfRange, &range) else {
            if let field = markerSnapshot(element: element, pid: pid, rightLimit: rightLimit) { return field }
            report("prediction.caret")
            return nil
        }
        guard range.length == 0, range.location > 0 else { return nil }
        let left = max(0, range.location - 128)
        let nearby: (before: String, after: String, length: Int)?
        if let length = attribute(element, kAXNumberOfCharactersAttribute) as? Int, length >= range.location,
           let before = text(element, from: left, length: range.location - left),
           let after = text(element, from: range.location, length: min(rightLimit, length - range.location)) {
            nearby = (before, after, length)
        } else if let value = attribute(element, kAXValueAttribute) as? NSString,
                  value.length >= range.location {
            nearby = (value.substring(with: NSRange(location: left, length: range.location - left)),
                      value.substring(with: NSRange(location: range.location, length: min(rightLimit, value.length - range.location))),
                      value.length)
        } else {
            if let field = markerSnapshot(element: element, pid: pid, rightLimit: rightLimit) { return field }
            report("prediction.field")
            return nil
        }
        guard let (before, after, length) = nearby,
              let geometry = CaretLocator.inlineGeometry(in: element, at: range.location, before: before, after: after, viewport: frame(of: element)) else {
            if let field = markerSnapshot(element: element, pid: pid, rightLimit: rightLimit) { return field }
            report("prediction.caret")
            return nil
        }
        return Field(element: element, pid: pid, position: range.location, length: length, before: before, after: after,
                     startsAtFieldStart: left == 0, endsAtFieldEnd: length - range.location <= rightLimit,
                     geometry: geometry, viewport: frame(of: element))
    }

    // Web editors can expose selection and bounds as text markers instead of UTF-16 ranges.
    private static func markerSnapshot(element: AXUIElement, pid: pid_t, rightLimit: Int) -> Field? {
        func parameter(_ name: String, _ value: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
            return result
        }

        let length = "AXLengthForTextMarkerRange"
        let start = "AXStartTextMarkerForTextMarkerRange"
        let end = "AXEndTextMarkerForTextMarkerRange"
        let span = "AXTextMarkerRangeForUnorderedTextMarkers"
        let string = "AXStringForTextMarkerRange"
        guard let selected = attribute(element, "AXSelectedTextMarkerRange"),
              parameter(length, selected) as? Int == 0,
              let cursor = parameter(start, selected),
              let full = parameter("AXTextMarkerRangeForUIElement", element),
              let count = parameter(length, full) as? Int, (1...16_384).contains(count),
              let first = parameter(start, full), let last = parameter(end, full),
              let left = parameter(span, [first, cursor] as CFArray),
              let right = parameter(span, [cursor, last] as CFArray),
              let before = parameter(string, left) as? NSString,
              let after = parameter(string, right) as? NSString,
              before.length > 0, before.length + after.length == count else { return nil }
        let leftText = before.substring(from: max(0, before.length - 128))
        let rightText = after.substring(to: min(rightLimit, after.length))
        guard let geometry = CaretLocator.inlineGeometry(in: element, at: before.length,
            before: leftText, after: rightText, viewport: frame(of: element), selectedMarker: selected) else { return nil }
        return Field(element: element, pid: pid, position: before.length, length: count,
                     before: leftText,
                     after: rightText, startsAtFieldStart: before.length <= 128,
                     endsAtFieldEnd: after.length <= rightLimit,
                     geometry: geometry, viewport: frame(of: element))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func text(_ element: AXUIElement, from start: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: start, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success,
              let string = result as? String, string.utf16.count == length else { return nil }
        return string
    }

    private static func keyboardLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
              CFEqual(Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue(), kTISTypeKeyboardLayout),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }

    private func show(_ candidate: Suggestion) -> Bool {
        let caret = CaretLocator.flipToCocoa(candidate.field.bounds)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret.insetBy(dx: -1, dy: 0)) }) else { return false }
        let label = NSTextField(labelWithString: candidate.suffix)
        label.font = candidate.field.geometry.font ?? .systemFont(ofSize: min(32, max(9, caret.height * 0.78)))
        label.textColor = .systemGray
        if candidate.trigger.isInfill {
            return showInfill(label, near: caret, on: screen)
        }
        let fieldRight = candidate.field.viewport.map { CaretLocator.flipToCocoa($0).maxX } ?? screen.visibleFrame.maxX
        func fit() -> NSRect? {
            label.sizeToFit()
            label.setFrameOrigin(.zero)
            let frame = CaretLocator.inlineFrame(caret: caret, label: label)
            return screen.visibleFrame.contains(frame) && frame.maxX <= fieldRight ? frame : nil
        }
        var fitted = fit()
        // Close to the right edge, show exactly the word the shortcut would accept.
        if fitted == nil {
            label.stringValue = PredictionPhrase.firstChunk(candidate.suffix)
            fitted = fit()
        }
        guard let frame = fitted else { return false }

        displayOverlay(label, frame: frame)
        return true
    }

    private func showInfill(_ label: NSTextField, near caret: CGRect, on screen: NSScreen) -> Bool {
        label.sizeToFit()
        let padding = NSSize(width: 7, height: 3)
        let size = NSSize(width: label.frame.width + padding.width * 2, height: label.frame.height + padding.height * 2)
        let visible = screen.visibleFrame
        guard size.width <= visible.width else { return false }
        let above = caret.maxY + 3
        let y = above + size.height <= visible.maxY ? above : caret.minY - size.height - 3
        let x = min(max(caret.minX, visible.minX), visible.maxX - size.width)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard visible.contains(frame) else { return false }
        let bubble = NSView(frame: CGRect(origin: .zero, size: size))
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bubble.layer?.cornerRadius = 5
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = NSColor.separatorColor.cgColor
        label.textColor = .labelColor
        label.setFrameOrigin(CGPoint(x: padding.width, y: padding.height))
        bubble.addSubview(label)
        displayOverlay(bubble, frame: frame)
        return true
    }

    private func displayOverlay(_ content: NSView, frame: CGRect) {
        if overlay == nil {
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.level = .floating
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
            overlay = window
        }
        overlay?.contentView = content
        overlay?.setFrame(frame, display: true)
        overlay?.orderFrontRegardless()
    }
}

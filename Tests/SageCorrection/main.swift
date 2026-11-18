import Foundation

precondition(SageCorrectionText.supports("Я думаю что это опичатка."))
precondition(!SageCorrectionText.supports("A sentence in English"))
precondition(!SageCorrectionText.supports("Фото\u{FFFC} внутри текста"))
precondition(!SageCorrectionText.supports("`комментарий` https://example.com"))
precondition(SageCorrectionText.validated("Я думаю, что это опечатка.", for: "  Я думаю что это опичатка.\r\n") == "  Я думаю, что это опечатка.\r\n")
precondition(SageCorrectionText.validated("Первая. Вторая.", for: "Первая\nВторая") == nil)
precondition(SageCorrectionText.validated("Проверь https://bad.test", for: "Проверь https://site.test") == nil)
precondition(SageCorrectionText.validated("Проверь `user_id`.", for: "Проверь `user_id`") == "Проверь `user_id`.")
precondition(SageCorrectionText.validated("Создай MR.", for: "Создай PR.") == nil)
precondition(SageCorrectionText.validated("Сумма 50 рублей.", for: "Сумма 500 рублей.") == nil)
precondition(SageCorrectionText.validated("Имя\u{0000}", for: "Имя") == nil)
print("SAGE correction: Russian text, formatting and protected fragments passed")

let typed = "Старый текст. Я думаю что это опичатка. "
let current = SageCorrectionText.typingRange(before: typed, startsAtFieldStart: true)!
precondition((typed as NSString).substring(with: current) == "Я думаю что это опичатка. ")
let multiline = "🙂 Заголовок\r\nЯ пичатаю"
let line = SageCorrectionText.typingRange(before: multiline, startsAtFieldStart: false)!
precondition((multiline as NSString).substring(with: line) == "Я пичатаю")
precondition(SageCorrectionText.typingRange(before: "хвост длинного предложения", startsAtFieldStart: false) == nil)
precondition(SageCorrectionText.typingRange(before: "Only English", startsAtFieldStart: true) == nil)
precondition(SageCorrectionText.typingRange(before: "Я", startsAtFieldStart: true) == nil)
let edit = SageCorrectionText.typingEdit(from: "Я думаю что это опичатка. ", to: "Я думаю, что это опечатка. ")!
precondition(edit.range == NSRange(location: 7, length: 12))
precondition(("Я думаю что это опичатка. " as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "Я думаю, что это опечатка. ")
let insertion = SageCorrectionText.typingEdit(from: "Я думаю что да.", to: "Я думаю, что да.")!
precondition(insertion.range == NSRange(location: 7, length: 0) && insertion.replacement == ",")
precondition(SageCorrectionText.typingEdit(from: "Увидимся послезавтра!", to: "Больше никогда не встречаемся.") == nil)
precondition(SageCorrectionText.typingEdit(from: "Один и тот же текст", to: "Один и тот же текст") == nil)
print("SAGE typing: sentence boundaries and minimal guarded edits passed")


let longDictation = String(repeating: "Проверь, пожалуйста, адрес перед отправкой. ", count: 24)
    + "\r\n" + String(repeating: "a", count: 800) + "  " + "Готово."
let dictationParts = SageCorrectionText.dictationChunks(longDictation)
precondition(dictationParts.joined() == longDictation && dictationParts.contains("\r\n"))
precondition(dictationParts.filter(SageCorrectionText.supports).allSatisfy {
    $0.utf8.count <= SageCorrectionText.dictationChunkBytes
})
precondition(SageCorrectionText.validatedDictation("Я не знал, что ты придёшь.", for: "Я не знал что ты придешь") == "Я не знал, что ты придёшь.")
precondition(SageCorrectionText.validatedDictation("отправь 50 писем.", for: "отправь 5 писем") == nil)
precondition(SageCorrectionText.validatedDictation("отправь в ChatGPT.", for: "отправь в Codex") == nil)
print("SAGE dictation: bounded fragments, local edits and protected identifiers passed")

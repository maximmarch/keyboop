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

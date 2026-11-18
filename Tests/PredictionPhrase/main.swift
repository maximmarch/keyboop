import Foundation

func kbLog(_ message: String) {}

for (phrase, expected) in [("документ сегодня", "документ"), (" сегодня", " сегодня"),
                            ("le later today", "le"), ("", "")] {
    precondition(PredictionPhrase.firstChunk(phrase) == expected)
}
let buffer = KeystrokeBuffer()
buffer.append("доку")
buffer.appendSuggestedSuffix("мент")
buffer.appendSuggestedSuffix(" сегодня")
precondition(buffer.lastWord == "документ" && buffer.lastTail == " " && buffer.currentWord == "сегодня")
precondition(buffer.sessionWords.count == 1)
let verify = PredictionPhrase.matchesEdit
precondition(verify("письмо ", "", "PR", 7, "письмо\u{00a0}PR", "", 9))
precondition(verify("abc🙂", "", "de", 5, "c🙂de", "", 7))
precondition(!verify("abc", "", "de", 3, "abcdf", "", 5))
precondition(!verify("abc", "", "de", 3, "abcde", "X", 5))
precondition(!verify("abc", "", "de", 3, "abcde", "", 6))
print("11 phrase acceptance and buffer checks passed")

let finishWord = PredictionPhrase.acceptFirstWord("йста")
precondition(finishWord?.insertion == "йста " && finishWord?.remainder == "")
let nextWord = PredictionPhrase.acceptFirstWord("пор")
precondition(nextWord?.insertion == "пор " && nextWord?.remainder == "")
let phraseStart = PredictionPhrase.acceptFirstWord("мент сегодня утром")
precondition(phraseStart?.insertion == "мент " && phraseStart?.remainder == "сегодня утром")
let phraseMiddle = PredictionPhrase.acceptFirstWord(phraseStart!.remainder)
precondition(phraseMiddle?.insertion == "сегодня " && phraseMiddle?.remainder == "утром")
let phraseEnd = PredictionPhrase.acceptFirstWord(phraseMiddle!.remainder)
precondition(phraseEnd?.insertion == "утром " && phraseEnd?.remainder == "")
// If the user finished the current word by hand, the preview still has a leading separator.
let afterTyping = PredictionPhrase.acceptFirstWord(" сегодня утром")
precondition(afterTyping?.insertion == " сегодня " && afterTyping?.remainder == "утром")
precondition(PredictionPhrase.acceptFirstWord(" ") == nil)
let closed = KeystrokeBuffer()
closed.append("доку")
closed.appendSuggestedSuffix(phraseStart!.insertion)
precondition(closed.lastWord == "документ" && closed.lastTail == " " && closed.currentWord.isEmpty)
closed.appendSuggestedSuffix(phraseMiddle!.insertion)
precondition(closed.lastWord == "сегодня" && closed.lastTail == " " && closed.currentWord.isEmpty)
precondition(closed.sessionWords.map(\.tail) == [" ", " "])
precondition(verify("доку", "\n", "мент ", 4, "документ\u{00a0}", "\n", 9))
print("11 trailing-space acceptance checks passed")

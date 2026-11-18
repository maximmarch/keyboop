import Foundation

private func check(_ condition: Bool, _ label: String) {
    if !condition {
        FileHandle.standardError.write(Data("Failed: \(label)\n".utf8))
        exit(1)
    }
}

// A complete byte alphabet and a few overlapping merges; the normal tests need no downloads.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let vocabPath = directory.appendingPathComponent("vocab.json")
let mergePath = directory.appendingPathComponent("merges.txt")
let literalBytes = Set(Array(33...126) + Array(161...172) + Array(174...255))
var nextCodePoint: UInt32 = 256
var vocabulary: [String: Int64] = ["<pad>": 0, "<s>": 1, "</s>": 2, "<unk>": 3, "<mask>": 4]
for byte in 0...255 {
    let codePoint = literalBytes.contains(byte) ? UInt32(byte) : nextCodePoint
    vocabulary[String(Unicode.Scalar(codePoint)!)] = Int64(byte + 10)
    if !literalBytes.contains(byte) { nextCodePoint += 1 }
}
for (index, word) in ["lo", "low", "Ġlow", "er", "Ġlower"].enumerated() {
    vocabulary[word] = Int64(300 + index)
}
try JSONEncoder().encode(vocabulary).write(to: vocabPath)
try "#version: 0.2\nl o\nlo w\nĠ low\ne r\nĠlow er\n".write(to: mergePath, atomically: true, encoding: .utf8)
let tokenizer = try SageTokenizer(vocabulary: vocabPath, merges: mergePath)
check(try tokenizer.encode("low lower") == [50357, 301, 304], "ranked merges and leading space")
check(try tokenizer.encode("Я🙂") == [50357, 218, 185, 250, 169, 163, 140], "Cyrillic and emoji as UTF-8 bytes")
check(try tokenizer.encode("") == [50357], "encoder adds <LM> and no EOS")
check(try tokenizer.decode([0, 1, 50357, 304, 50257, 50362, 2]) == " lower", "decoder skips model control IDs")
let original = "проверь Cafe\u{0301}\r\n\t  её 🍎  "
let decoded = try tokenizer.decode(tokenizer.encode(original))
check(Array(decoded.utf8) == Array(original.utf8), "accent, whitespace, emoji and Cyrillic round trip")
check((try? tokenizer.encode(String(repeating: "x", count: 512))) == nil, "512 tokens include the encoder prefix")
check((try? tokenizer.decode([100_000])) == nil, "unknown output id rejected")
check((try? tokenizer.decode([250])) == nil, "truncated UTF-8 output rejected")
print("SageTokenizer: byte mapping, BPE rank, special tokens and length checks passed")

// Optional test of the official vocab/merges. Expected IDs come from Hugging Face
// tokenizers' ByteLevel BPE using the model's configured encoder BOS.
if let officialPath = CommandLine.arguments.dropFirst().first {
    let official = URL(fileURLWithPath: officialPath, isDirectory: true)
    let tokenizer = try SageTokenizer(vocabulary: official.appendingPathComponent("vocab.json"),
                                      merges: official.appendingPathComponent("merges.txt"))
    let fixtures: [(String, [Int64])] = [
        ("Я хачу чтобы всё роботало.", [50357, 1358, 2012, 1616, 753, 1653, 29162, 576, 18]),
        ("Привт как деал", [50357, 4670, 275, 266, 428, 744, 300]),
        ("Когда дождь закончится мы пойдём гулять", [50357, 5798, 11511, 20372, 656, 2293, 29580, 25159]),
        ("Не трогай PR №25 — всё ок 🙂", [50357, 3096, 22855, 686, 23568, 4855, 4691, 510, 1653, 790, 225, 34115, 252, 229]),
        ("проверь Cafe\u{0301}\r\n\t  её 🍎  ",
         [50357, 293, 7819, 278, 769, 9845, 73, 2442, 206, 203, 202, 225, 1847, 225, 34115, 240, 241, 2424]),
        ("  test\n\t he'll DON'T 10,5\u{00A0}мс",
         [50357, 225, 21832, 203, 202, 1547, 11, 5784, 1130, 18689, 11, 56, 1533, 16, 25, 369, 10905]),
        ("И не чсно прохожим в этот день непогожйи почему я веселый такйо",
         [50357, 732, 322, 327, 1499, 21020, 406, 282, 1177, 1119, 37320, 362, 295, 265, 2006, 417, 33238, 453, 295, 262])
    ]
    for (index, fixture) in fixtures.enumerated() {
        check(try tokenizer.encode(fixture.0) == fixture.1, "official token IDs for case \(index + 1)")
        check(Array(try tokenizer.decode(fixture.1).utf8) == Array(fixture.0.utf8), "official round trip for case \(index + 1)")
    }
    print("SageTokenizer: \(fixtures.count) official GPT-2 BPE reference cases passed")
}

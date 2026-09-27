import Foundation
import LayaCore

/// Swift tokenizer benchmark — the CHALLENGER in the Python-vs-Swift A/B.
/// Mirrors Scripts/bench_tokenizer_py.py exactly: same corpus
/// (golden/bench_corpus.json), same warm-up policy (3 passes), same timing
/// (10 passes, median reported), same short/long split.
///
/// Usage: laya-tokenizer-bench <tokenizer.json> [bench_corpus.json] [--json out.json]

func loadTexts(_ path: String) throws -> [String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    // Minimal scan for {"texts": [...]} without depending on LayaCore's
    // internal JSONValue: decode with JSONSerialization instead.
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any], let arr = dict["texts"] as? [String] else {
        throw NSError(domain: "bench", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "bad corpus \(path)"])
    }
    return arr
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: laya-tokenizer-bench <tokenizer.json> [bench_corpus.json] [--json out.json]\n".utf8))
    exit(2)
}
let tokPath = args[1]
var corpusPath = ""
var jsonOut = ""
var nextIsJson = false
for a in args.dropFirst(2) {
    if nextIsJson { jsonOut = a; nextIsJson = false; continue }
    if a == "--json" { nextIsJson = true; continue }
    if corpusPath.isEmpty { corpusPath = a }
}
if corpusPath.isEmpty {
    corpusPath = FileManager.default.currentDirectoryPath + "/golden/bench_corpus.json"
}

let t0 = Date()
let tok = try LayaTokenizer.load(fromFile: tokPath)
let loadS = Date().timeIntervalSince(t0)

let texts = try loadTexts(corpusPath)
let totalChars = texts.reduce(0) { $0 + $1.unicodeScalars.count }
let passes = 10, warmup = 3

func pass() -> (seconds: Double, tokens: Int) {
    let s = Date()
    var ntok = 0
    for t in texts { ntok += tok.encode(t).count }
    return (Date().timeIntervalSince(s), ntok)
}

for _ in 0..<warmup { _ = pass() }

var timings: [Double] = []
var lastTokens = 0
for _ in 0..<passes {
    let (sec, ntok) = pass()
    timings.append(sec)
    lastTokens = ntok
}
timings.sort()
let medianPass = timings[timings.count / 2]
let bestPass = timings[0]
let totalTokTime = timings.reduce(0, +)

func subsetUs(_ filter: (String) -> Bool) -> Double? {
    let sub = texts.filter(filter)
    guard !sub.isEmpty else { return nil }
    var ps: [Double] = []
    for _ in 0..<passes {
        let s = Date()
        for t in sub { _ = tok.encode(t) }
        ps.append(Date().timeIntervalSince(s))
    }
    ps.sort()
    return ps[ps.count / 2] / Double(sub.count) * 1e6
}

let shortUs = subsetUs { $0.unicodeScalars.count < 200 }
let longUs = subsetUs { $0.unicodeScalars.count >= 4096 }

var lines: [String] = [
    "\"impl\": \"laya-core tokenizer (swift)\"",
    "\"load_seconds\": \((loadS * 1000).rounded() / 1000)",
    "\"texts\": \(texts.count)",
    "\"total_chars\": \(totalChars)",
    "\"median_pass_s\": \((medianPass * 1e6).rounded() / 1e6)",
    "\"best_pass_s\": \((bestPass * 1e6).rounded() / 1e6)",
    "\"tokens_per_s_median_pass\": \(Int((Double(lastTokens * passes) / totalTokTime).rounded()))",
    "\"chars_per_s_median_pass\": \(Int((Double(totalChars) / medianPass).rounded()))",
]
if let s = shortUs { lines.append("\"short_text_us\": \((s * 10).rounded() / 10)") }
if let l = longUs { lines.append("\"long_text_us\": \((l * 10).rounded() / 10)") }

let out = "{\n  " + lines.joined(separator: ",\n  ") + "\n}\n"
if jsonOut.isEmpty {
    print(out, terminator: "")
} else {
    try out.write(toFile: jsonOut, atomically: true, encoding: .utf8)
    print(out, terminator: "")
}

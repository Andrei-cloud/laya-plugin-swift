import Foundation
import LayaCore

/// Swift tokenizer benchmark — the CHALLENGER in the Python-vs-Swift A/B.
/// Mirrors Scripts/bench_tokenizer_py.py: same corpus
/// (golden/bench_corpus.json), same warm-up policy (3 passes), same timing
/// (10 passes, median reported), same short/long split.
///
/// B1: reports BOTH cache-bypassed (real BPE work, comparable to the Python
/// challenger which has no chunk cache) and warm-cache medians as separate
/// fields. B2: text lengths are precomputed once, never inside timed loops.
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
// B2: one walk for lengths; everything downstream filters on lens[i].
let lens = texts.map { $0.unicodeScalars.count }
let totalChars = lens.reduce(0, +)
let passes = 10, warmup = 3

func pass() -> (seconds: Double, tokens: Int) {
    let s = Date()
    var ntok = 0
    for t in texts { ntok += tok.encode(t).count }
    return (Date().timeIntervalSince(s), ntok)
}

/// One timing mode: warmup+passes. cold = cache-bypassed (real BPE work).
func timed(cold: Bool) -> (median: Double, best: Double, tokens: Int, total: Double) {
    tok.cacheBypass = cold
    if cold { tok.clearChunkCache() }
    for _ in 0..<warmup { _ = pass() }
    var timings: [Double] = []
    var lastTokens = 0
    for _ in 0..<passes {
        let (sec, ntok) = pass()
        timings.append(sec)
        lastTokens = ntok
    }
    timings.sort()
    return (timings[timings.count / 2], timings[0], lastTokens, timings.reduce(0, +))
}

func subsetUs(_ match: (Int) -> Bool, cold: Bool) -> Double? {
    let idx = lens.indices.filter { match(lens[$0]) }
    guard !idx.isEmpty else { return nil }
    tok.cacheBypass = cold
    if cold { tok.clearChunkCache() }
    var ps: [Double] = []
    for _ in 0..<passes {
        let s = Date()
        for i in idx { _ = tok.encode(texts[i]) }
        ps.append(Date().timeIntervalSince(s))
    }
    ps.sort()
    return ps[ps.count / 2] / Double(idx.count) * 1e6
}

// cold first so the warm pass builds the cache from scratch afterwards
let cold = timed(cold: true)
let warm = timed(cold: false)
tok.cacheBypass = false

var lines: [String] = [
    "\"impl\": \"laya-core tokenizer (swift)\"",
    "\"load_seconds\": \((loadS * 1000).rounded() / 1000)",
    "\"texts\": \(texts.count)",
    "\"total_chars\": \(totalChars)",
    "\"mode\": \"cold+warm\"",
    "\"median_pass_s_cold\": \((cold.median * 1e6).rounded() / 1e6)",
    "\"best_pass_s_cold\": \((cold.best * 1e6).rounded() / 1e6)",
    "\"median_pass_s_warm\": \((warm.median * 1e6).rounded() / 1e6)",
    "\"tokens_per_s_cold\": \(Int((Double(cold.tokens * passes) / cold.total).rounded()))",
    "\"tokens_per_s_warm\": \(Int((Double(warm.tokens * passes) / warm.total).rounded()))",
    "\"chars_per_s_cold\": \(Int((Double(totalChars) / cold.median).rounded()))",
]
for (label, coldFlag) in [("_cold", true), ("_warm", false)] {
    if let s = subsetUs({ $0 < 200 }, cold: coldFlag) {
        lines.append("\"short_text_us\(label)\": \((s * 10).rounded() / 10)")
    }
    if let l = subsetUs({ $0 >= 4096 }, cold: coldFlag) {
        lines.append("\"long_text_us\(label)\": \((l * 10).rounded() / 10)")
    }
}

let out = "{\n  " + lines.joined(separator: ",\n  ") + "\n}\n"
if jsonOut.isEmpty {
    print(out, terminator: "")
} else {
    try out.write(toFile: jsonOut, atomically: true, encoding: .utf8)
    print(out, terminator: "")
}

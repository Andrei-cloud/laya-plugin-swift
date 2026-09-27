import XCTest
@testable import LayaCore

/// The E2/E6 fast paths must be EXACTLY equivalent to the naive
/// serialize-then-measure paths, on adversarial shapes: control chars
/// (\uXXXX = 6 output scalars), non-BMP emoji (2 UTF-16 units but 1
/// scalar — the count is scalar-based), budget cut mid-escape, empty
/// containers, nested separators.
final class JSONValueBoundedWriterTests: XCTestCase {

    let adversarial: [JSONValue] = [
        .string("plain"),
        .string("tab\tnl\ncr\rbell\u{07}form\u{0C}"),
        .string("emoji 👍 rocket 🚀"),          // non-BMP: 1 scalar each
        .string("quote\" backslash\\"),
        .string(""),
        .object([("b", .int(1)), ("a", .string("x"))]),
        .object([("k", .array([.string("a"), .null, .bool(true), .double(1.5)]))]),
        .array([]), .object([]),
        .object([("z", .object([("y", .object([("x", .string("deep"))]))]))]),
        .double(1e300), .double(-0.0), .double(0.1),
        .int(-9007199254740993),
    ]

    /// First `n` Unicode scalars of s (Python str[:n] semantics — NOT
    /// Swift's Character-based prefix, which counts grapheme clusters).
    func scalarPrefix(_ s: String, _ n: Int) -> String {
        var out = ""
        var k = 0
        for scalar in s.unicodeScalars {
            if k >= n { break }
            out.unicodeScalars.append(scalar)
            k += 1
        }
        return out
    }

    func testCharLenMatchesSerialize() throws {
        for v in adversarial {
            let expect = JSONValue.serialize(v, sortKeys: false).unicodeScalars.count
            XCTAssertEqual(JSONValue.charLen(v), expect, "charLen mismatch: \(v)")
        }
        // the golden corpus payloads too
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("golden/wire_golden.json")
        if let data = try? Data(contentsOf: url),
           let g = JSONValue.parse(data) {
            for c in g["cases"]?.arrayValue ?? [] {
                if let state = c["payload"]?["state"] {
                    let expect = JSONValue.serialize(state, sortKeys: false).unicodeScalars.count
                    XCTAssertEqual(JSONValue.charLen(state), expect)
                }
            }
        }
    }

    func testSerializeSortedPrefixMatchesNaive() throws {
        // bounded writer == full ensure_ascii=True dump, scalar-prefix-wise,
        // at every boundary; full dump == Python golden.
        for v in adversarial {
            let full = JSONValue.serializeAsciiSorted(v)
            for budget in [0, 1, 2, 3, 5, 8, 13, 21, 40, 97, 900, 5000] {
                let fast = JSONValue.serializeSortedPrefix(v, maxScalars: budget)
                let naive = scalarPrefix(full, budget)
                XCTAssertEqual(Array(fast.unicodeScalars), Array(naive.unicodeScalars),
                               "prefix(\(budget)) mismatch for \(v)")
            }
        }
    }

    func testAsciiDumpMatchesPythonGolden() throws {
        // Python-truth: golden/ascii_slate_golden.json holds
        // json.dumps(v, sort_keys=True)[:N] with defaults for 14 shapes.
        let path = FileManager.default.currentDirectoryPath
            + "/golden/ascii_slate_golden.json"
        guard let data = FileManager.default.contents(atPath: path),
              let gold = JSONValue.parse(data) else {
            return XCTFail("run from repo root; golden/ascii_slate_golden.json required")
        }
        var checked = 0
        for (name, c) in gold.objectPairs ?? [] {
            // c["full"] is the Python dump (pure ASCII) — reparse it to
            // get the case value, then re-dump with our writer.
            guard let fullStr = c["full"]?.stringValue,
                  let v = JSONValue.parse(fullStr) else {
                return XCTFail("case \(name): golden unparseable")
            }
            let ours = JSONValue.serializeAsciiSorted(v)
            XCTAssertEqual(Array(ours.unicodeScalars), Array(fullStr.unicodeScalars),
                           "case \(name): full dump mismatch")
            for (key, budget) in [("p0", 0), ("p1", 1), ("p5", 5), ("p13", 13),
                                  ("p40", 40), ("p97", 97), ("p900", 900)] {
                if let want = c[key]?.stringValue {
                    let got = JSONValue.serializeSortedPrefix(v, maxScalars: budget)
                    XCTAssertEqual(Array(got.unicodeScalars), Array(want.unicodeScalars),
                                   "case \(name) budget \(budget)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 14 * 7)
    }

    func testPrefix900OnBigState() throws {
        // 200-key object: naive full dump is ~10 KB; prefix 900 must match.
        var pairs = [(key: String, value: JSONValue)]()
        for i in 0..<200 {
            pairs.append((key: String(format: "key_%03d_é中", i),
                          value: .string("value \(i) with \t escape")))
        }
        let v: JSONValue = .object(pairs)
        let naive = scalarPrefix(JSONValue.serializeAsciiSorted(v), 900)
        let fast = JSONValue.serializeSortedPrefix(v, maxScalars: 900)
        XCTAssertEqual(Array(fast.unicodeScalars), Array(naive.unicodeScalars))
    }

    // MARK: - J1 differential: UTF-8-native scanner vs UTF-16 oracle

    func testUTF8ParserMatchesUTF16Oracle() throws {
        // Synthetic cases covering every escape branch, surrogate
        // pairing, number forms, and nesting.
        let cases = [
            #"{"a":1,"b":-2.5,"c":1e10,"d":true,"e":false,"f":null}"#,
            #""tab\tnl\nq\"r bs\\ sl/ b\b f\f""#,
            #""é \u00e9 \uD83D\uDE00""#,           // escape + glued surrogate pair
            #"[[],{},[[[]]],{"k":[{"":1}]}]"#,
            #"{"neg0":-0,"exp":1E+2,"frac":0.5}"#,
            "\"\"",
        ]
        for src in cases {
            let a = JSONValue.parse(Array(src.utf8))
            let b = JSONValue.parse(src)
            XCTAssertEqual(a ?? .null, b ?? .null, "parser divergence on \(src)")
        }
        // DOCUMENTED divergence (accepted): a LONE surrogate — the
        // UTF-16 oracle keeps the raw code unit (Python len() parity),
        // the UTF-8 scanner U+FFFD-substitutes (CESU-8 dead end).
        // tokenizer.json contains none; the full-file test is the gate.
        let lone = #""a\uD800b""#
        XCTAssertNotEqual(JSONValue.parse(Array(lone.utf8)), JSONValue.parse(lone))
    }

    func testUTF8ParserOnRealTokenizerFile() throws {
        // The production file: 34 MB, vocab 256k, merges 580k. Both
        // parsers must build the IDENTICAL tree (lone surrogates would
        // diverge — tokenizer.json contains none; this test is the gate
        // that keeps that assumption true).
        let path = ProcessInfo.processInfo.environment["LAYA_TOKENIZER_JSON"]
            ?? "/Users/andrei/Developer/ai/laya/models/source/tokenizer/tokenizer.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("tokenizer.json not present")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path),
                            options: [.mappedIfSafe])
        let a0 = ContinuousClock.now
        let utf8 = data.withUnsafeBytes { JSONValue.parse([UInt8]($0.bindMemory(to: UInt8.self))) }
        let utf8s = a0.duration(to: .now)
        let b0 = ContinuousClock.now
        let s = String(decoding: data, as: UTF8.self)   // the old copy chain
        let old = JSONValue.parse(s)
        let oldS = b0.duration(to: .now)
        XCTAssertNotNil(utf8)
        XCTAssertNotNil(old)
        // Full structural equality — hand-written == walks the whole tree.
        XCTAssertEqual(utf8, old, "UTF-8 scanner diverged from UTF-16 oracle on tokenizer.json")
        print(String(format: "J1 timing: utf8-scan %.3fs vs utf16-chain %.3fs",
                     Double(utf8s.components.seconds) + Double(utf8s.components.attoseconds) / 1e18,
                     Double(oldS.components.seconds) + Double(oldS.components.attoseconds) / 1e18))
    }
}

import XCTest
@testable import LayaCore

/// Byte-parity against the real installed tokenizer's outputs, frozen as
/// goldens (Scripts/make_token_corpus.py regenerates; seed 777 is fixed).
/// These are the same 4,021 strings the Python replica proved
/// byte-identical — the Swift port must replay them exactly.
@MainActor
final class TokenizerParityTests: XCTestCase {
    nonisolated(unsafe) static var tok: LayaTokenizer!
    static let modelDir = "/Users/andrei/Developer/ai/laya/models/source/tokenizer"

    override class func setUp() {
        super.setUp()
        if tok == nil {
            tok = try! LayaTokenizer.load(fromFile: modelDir + "/tokenizer.json")
        }
    }

    func loadJSON(_ rel: String) -> JSONValue {
        // .../laya-plugin-swift/Tests/LayaCoreTests/this-file → repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        let data = try! Data(contentsOf: URL(fileURLWithPath: root + "/" + rel))
        guard let v = JSONValue.parse(data) else {
            XCTFail("unparseable golden \(rel)"); return .null
        }
        return v
    }

    func testSpecialIdsMatchGolden() throws {
        let g = loadJSON("golden/tokenizer_golden.json")["tokenizer"]!
        XCTAssertEqual(Int(Self.tok.clsId), Int(g["cls_id"]!.intValue!))
        XCTAssertEqual(Int(Self.tok.sepId), Int(g["sep_id"]!.intValue!))
        XCTAssertEqual(Int(Self.tok.padId), Int(g["pad_id"]!.intValue!))
        XCTAssertEqual(Int(Self.tok.maskId), Int(g["mask_id"]!.intValue!))
        XCTAssertEqual(Self.tok.maskTok, g["mask_tok"]!.stringValue)
    }

    /// Unicode canonical-equivalence regression: Swift's String == treats
    /// ";" (U+003B) and ";" (U+037E GREEK QUESTION MARK) as EQUAL, which
    /// silently merged two distinct vocab entries and flipped the supervise
    /// chain's answer on wire_golden (found live: `;`→235289 was overwritten
    /// by `;`→244780). The vocab must stay byte-exact like Python/Rust.
    func testCanonicalEquivalenceVocabIsByteExact() throws {
        XCTAssertEqual(Self.tok.token(toId: ";").map(Int.init), 235289)
        XCTAssertEqual(Self.tok.token(toId: "\u{037E}").map(Int.init), 244780)
        XCTAssertEqual(Self.tok.id(toToken: 235289), ";")
        XCTAssertEqual(Self.tok.id(toToken: 244780), "\u{037E}")
        // encode keeps them distinct end-to-end (ground truth from the
        // installed HF tokenizer: ';' standalone gets its ▁-word token,
        // U+037E has no ▁-form and lands on its raw entry)
        XCTAssertEqual(Self.tok.encode("; \u{037E}"), [2161, 235248, 244780])
        XCTAssertEqual(Self.tok.encode("healthy; poll"), [9606, 235289, 11166])
        // and the whole wire golden suite must replay exactly
    }

    func testGoldenCases() throws {
        let cases = loadJSON("golden/tokenizer_golden.json")["tokenizer"]!["cases"]!.arrayValue!
        var failed = 0
        for c in cases {
            let text = c["text"]!.stringValue!
            let want = c["ids"]!.arrayValue!.map { UInt32($0.intValue!) }
            if Self.tok.encode(text) != want { failed += 1 }
        }
        XCTAssertEqual(failed, 0, "\(failed)/\(cases.count) golden texts diverge")
    }

    /// The 4,021-string corpus (21 goldens + seed-777 fuzz alphabet).
    func testCorpusParity() throws {
        let corpus = loadJSON("golden/token_corpus.json")
        XCTAssertEqual(Int(corpus["count"]!.intValue!), 4021)
        let pairs = corpus["pairs"]!.arrayValue!
        var failed: [String] = []
        for p in pairs {
            let text = p["text"]!.stringValue!
            let want = p["ids"]!.arrayValue!.map { UInt32($0.intValue!) }
            let got = Self.tok.encode(text)
            if got != want {
                failed.append(text)
                if failed.count >= 5 { break }
            }
        }
        XCTAssertTrue(failed.isEmpty,
                      "diverged (\(failed.count) shown): \(failed.prefix(5).map { String($0.prefix(60)) })")
    }

    /// build_sequence() parity: ids, MASK markers, rendered options.
    func testSeqCases() throws {
        let cases = loadJSON("golden/tokenizer_golden.json")["tokenizer"]!["seq_cases"]!.arrayValue!
        for c in cases {
            let state = JSONValue.string(c["state"]!.stringValue!)
            let q = c["q"]!
            let built = Sequence.buildSequence(tok: Self.tok, state: state, q: q,
                                               maxLength: 1024, headMaxLength: 256)
            let want = c["ids"]!.arrayValue!.map { UInt32($0.intValue!) }
            XCTAssertEqual(built.ids, want, "seq ids diverge for \(c["state"]!.stringValue!.prefix(40))")
            let wantMarkers = c["markers"]!.arrayValue!.map { Int($0.intValue!) }
            XCTAssertEqual(built.markers, wantMarkers)
            let wantOpts = c["opts"]!.arrayValue!.map { $0.stringValue! }
            XCTAssertEqual(Sequence.renderOptions(q), wantOpts)
        }
    }
}

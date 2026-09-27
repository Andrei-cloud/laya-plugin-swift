import XCTest
@testable import LayaCore

/// Differential equivalence: the O(n log n) linked-list+heap merge
/// (bpeHeap) must emit EXACTLY what the frozen O(n²) scan oracle (bpeScan)
/// emits — on the whole golden corpus and on long synthetic texts where
/// stale-heap-entry bugs live. The heap path only activates at/above
/// bpeHeapThreshold symbols, so both paths are forced across the corpus.
final class TokenizerDifferentialTests: XCTestCase {
    nonisolated(unsafe) static var tok: LayaTokenizer!
    static let modelDir = "/Users/andrei/Developer/ai/laya/models/source/tokenizer"

    override class func setUp() {
        super.setUp()
        if tok == nil {
            tok = try! LayaTokenizer.load(fromFile: modelDir + "/tokenizer.json")
        }
    }

    func corpus() -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        let data = try! Data(contentsOf: URL(fileURLWithPath: root + "/golden/token_corpus.json"))
        guard let v = JSONValue.parse(data), let pairs = v["pairs"]?.arrayValue else {
            XCTFail("corpus missing"); return []
        }
        return pairs.compactMap { $0["text"]?.stringValue }
    }

    /// Run `encode` with the merge path forced: threshold .max = always
    /// scan, threshold 1 = always heap. Cache must be cleared between.
    func forced(_ texts: [String], heapAlways: Bool) -> [[UInt32]] {
        Self.tok.bpeHeapThreshold = heapAlways ? 1 : .max
        Self.tok.clearChunkCache()
        let out = texts.map { Self.tok.encode($0) }
        Self.tok.bpeHeapThreshold = 12
        Self.tok.clearChunkCache()
        return out
    }

    func testHeapEqualsScanOnGoldenCorpus() throws {
        let texts = corpus()
        XCTAssertFalse(texts.isEmpty)
        let scan = forced(texts, heapAlways: false)
        let heap = forced(texts, heapAlways: true)
        var diffs = 0
        for i in texts.indices where scan[i] != heap[i] {
            if diffs < 5 {
                XCTFail("heap/scan diverge on \(texts[i].prefix(60)): "
                    + "\(scan[i].prefix(24)) vs \(heap[i].prefix(24))")
            }
            diffs += 1
        }
        XCTAssertEqual(diffs, 0, "heap path diverged on \(diffs) corpus strings")
    }

    func testHeapEqualsScanOnLongSyntheticTexts() throws {
        // Deterministic pseudo-random long texts (xorshift, fixed seed):
        // long chunks are exactly where stale heap entries and tie-order
        // bugs show up. Mix scripts + punctuation so merges interleave.
        var state: UInt64 = 0x2545F4914F6CDD1D
        func rnu(_ n: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(n))
        }
        let alphabet = Array("the quick brown fox jumps over lazy dogs; api_key: *** /tmp/x.md — 你好 Привет 🚀\n\t(){}[]<>#*_|")
        var texts: [String] = []
        for _ in 0..<40 {
            var s = ""
            let len = 200 + rnu(2000)
            for _ in 0..<len { s.append(alphabet[rnu(alphabet.count)]) }
            texts.append(s)
        }
        let scan = forced(texts, heapAlways: false)
        let heap = forced(texts, heapAlways: true)
        var diffs = 0
        for i in texts.indices where scan[i] != heap[i] {
            if diffs == 0 {
                XCTFail("heap/scan diverge on synthetic text \(i) (len \(texts[i].count))")
            }
            diffs += 1
        }
        XCTAssertEqual(diffs, 0)
    }

    func testRangePipelineEqualsLegacyChain() throws {
        // The production range-pipeline encode() must emit exactly what the
        // legacy String chain emits, on the full golden corpus (both merge
        // paths inside each). Cache cleared between so neither path's
        // warm cache can mask a divergence.
        let texts = corpus()
        XCTAssertFalse(texts.isEmpty)
        Self.tok.clearChunkCache()
        var diffs = 0
        for t in texts {
            let legacy = Self.tok.encodeLegacy(t)
            let range = Self.tok.encode(t)
            if legacy != range {
                if diffs < 3 {
                    XCTFail("range/legacy diverge on \(t.prefix(60)): "
                        + "\(legacy.prefix(20)) vs \(range.prefix(20))")
                }
                diffs += 1
            }
        }
        XCTAssertEqual(diffs, 0, "range pipeline diverged on \(diffs) strings")
    }
}

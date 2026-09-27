import Foundation

/// The mmBERT tokenizer — bit-exact Swift port of the empirically frozen
/// pipeline (golden/replica_reference.py: 5,385/5,385 probe strings
/// byte-identical against the installed tokenizers-0.23.2 + transformers
/// 5.17 stack). Do NOT "simplify" any stage — each was proven necessary by
/// differential fuzzing.
///
/// Pipeline per text:
///  1. added-token extraction (added_vocabulary.rs semantics): scan
///     left-to-right by Unicode scalar; the LONGEST added token starting
///     at a position wins and emits its id atomically. `<mask>` carries
///     lstrip: the whitespace run immediately left of the match is
///     ABSORBED (start = max(run start, start_offset)) and the absorbed
///     span emits NOTHING. The added set includes `\n`..`\n`×31 and
///     `\t\t`..`\t`×31 — that is what makes whitespace runs atomic before
///     Metaspace ever sees them.
///  2. per plain piece: normalizer Replace(" " -> "▁").
///  3. prepend "▁" unless the piece already starts with "▁".
///  4. fold-split on "▁" MergedWithNext over alternating intervals (each
///     "▁" char is its own match interval, each run of non-"▁" chars is
///     one interval; a reversed scan extends the following interval left).
///  5. BPE per chunk: one symbol per Unicode scalar (vocab hit; else byte
///     fallback "<0xNN>" iff EVERY UTF-8 byte token is in vocab; else a
///     single <unk>, consecutive unknowns fused); repeatedly merge the
///     lowest-rank adjacent pair (ties: leftmost), ONE instance per pass,
///     re-evaluating after each merge; rank = first JSON merges-list index
///     of the pair; merged id = vocab[a + b].
/// Open-addressing table for the 580k-entry merge-rank map (OPTIMIZATION.md
/// T2). Swift's Dictionary SipHashes every probe; these keys are
/// (aid<<32|bid) pairs with both halves < 262144, so the sentinel
/// UInt64.max is provably unreachable and a mix+linear-probe table is both
/// exact and several times faster on the BPE inner scan. Fixed after load
/// (inserts happen only while building), load factor ≤ 0.5.
struct PairRankTable: Sendable {
    private var keys: [UInt64]
    private var vals: [UInt64]
    private var mask: Int

    init(capacity: Int) {
        var cap = 1
        while cap < capacity * 2 { cap <<= 1 }
        keys = [UInt64](repeating: .max, count: cap)
        vals = [UInt64](repeating: 0, count: cap)
        mask = cap - 1
    }

    @inline(__always)
    private static func mix(_ k: UInt64) -> UInt64 {
        var x = k &* 0x9E3779B97F4A7C15
        x ^= x >> 29
        x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 32
        return x
    }

    /// First-wins insert (merges list is index-ordered; duplicates keep the
    /// lowest index). Returns true if the value was newly inserted.
    @discardableResult
    mutating func insertFirstWins(_ key: UInt64, _ value: UInt64) -> Bool {
        var i = Int(Self.mix(key) & UInt64(mask))
        while true {
            if keys[i] == .max { keys[i] = key; vals[i] = value; return true }
            if keys[i] == key { return false }
            i = (i + 1) & mask
        }
    }

    @inline(__always)
    func lookup(_ key: UInt64) -> UInt64? {
        var i = Int(Self.mix(key) & UInt64(mask))
        while true {
            let k = keys[i]
            if k == key { return vals[i] }
            if k == .max { return nil }
            i = (i + 1) & mask
        }
    }
}

public final class LayaTokenizer: @unchecked Sendable {
    /// Byte-exact string key. Swift's String `==`/`hash` implement Unicode
    /// CANONICAL equivalence — `";" == "\u{037E}"` is TRUE — which silently
    /// merges distinct vocab entries (this exact collision flipped the
    /// supervise chain: `;`→235289 was overwritten by `;`→244780). The
    /// Python/Rust tokenizer compares code points exactly, so every
    /// string-keyed table here keys on raw UTF-8 bytes instead.
    struct TokenKey: Hashable, Sendable {
        let bytes: [UInt8]
        init(_ s: String) { bytes = Array(s.utf8) }
    }
    /// vocab keyed byte-exactly (multi-char entries: merges, byte fallback).
    let vocabK: [TokenKey: UInt32]
    /// Single-scalar entries keyed by scalar value — exact integer compare,
    /// no hashing of strings on the BPE hot path.
    let scalarToId: [UInt32: UInt32]
    /// "<0xNN>" byte-fallback tokens, indexed by byte value (0 = absent).
    let byteTok: [UInt32]
    public var vocab: [String: UInt32] {
        var out: [String: UInt32] = [:]
        out.reserveCapacity(vocabK.count)
        for (k, v) in vocabK { out[String(decoding: k.bytes, as: UTF8.self)] = v }
        return out
    }
    private let vocabR: [UInt32: String]
    /// packed (aId << 32 | bId) -> packed (mergeIndex << 32 | newId)
    private let rank: PairRankTable
    /// added tokens, longest content first (first hit at a position wins)
    private let added: [(content: [Unicode.Scalar], first: Unicode.Scalar,
                         id: UInt32, lstrip: Bool)]
    /// first-scalar bucket index over `added` for O(1) position probes
    private let addedBuckets: [UInt32: [(content: [Unicode.Scalar], id: UInt32, lstrip: Bool)]]
    public let unkId: UInt32
    public let clsId: UInt32   // <bos>
    public let sepId: UInt32   // <eos>
    public let padId: UInt32   // <pad>
    public let maskId: UInt32  // <mask>
    public var maskTok: String { "<mask>" }

    /// U+2581, the Metaspace replacement letter.
    public static let repl: Unicode.Scalar = Unicode.Scalar(0x2581)!

    /// B1 (bench validity): when true, encode() skips the chunk cache and
    /// measures real BPE work. Bench-only knob; default off.
    public nonisolated(unsafe) var cacheBypass = false

    /// Drop all cached chunk results (bench mode transitions).
    public func clearChunkCache() {
        cacheLock.lock(); chunkCache.removeAll(keepingCapacity: true); cacheLock.unlock()
    }

    private let cacheLock = NSLock()
    /// BPE chunk cache keyed by SCALAR VALUES — exact integer equality,
    /// immune to the String canonical-equivalence trap (▁; vs ▁;).
    private var chunkCache: [[UInt32]: [UInt32]] = [:]

    // MARK: - Whitespace class

    /// Unicode White_Space — the Rust regex `\s` class this pipeline uses.
    /// NOT Swift's `isWhitespace` (the sets differ: U+1C…U+1F are excluded
    /// here, U+0020 is included — both discrepancies were fuzz-proven).
    static func isRustWS(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    // MARK: - Loading

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String), malformed(String)
        public var description: String {
            switch self {
            case .unreadable(let p): return "cannot read tokenizer.json at \(p)"
            case .malformed(let w):  return "tokenizer.json malformed: \(w)"
            }
        }
    }

    public static func load(fromFile path: String) throws -> LayaTokenizer {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw LoadError.unreadable(path) }
        guard let parsed = JSONValue.parse(data),
              case .object = parsed
        else { throw LoadError.malformed("root is not an object") }
        let root = parsed
        func pair(_ v: JSONValue?) -> [(key: String, value: JSONValue)]? {
            if case .object(let p)? = v { return p }
            return nil
        }
        func list(_ v: JSONValue?) -> [JSONValue]? {
            if case .array(let a)? = v { return a }
            return nil
        }
        guard let model = root["model"], pair(model) != nil,
              let vpairs = pair(model["vocab"]),
              let mlist = list(model["merges"])
        else { throw LoadError.malformed("model.vocab / model.merges missing") }

        var vocabK: [TokenKey: UInt32] = [:]
        vocabK.reserveCapacity(vpairs.count)
        var scalarToId: [UInt32: UInt32] = [:]
        var byteTok = [UInt32](repeating: 0, count: 256)
        for p in vpairs {
            guard let i = p.value.intValue, i >= 0 else { continue }
            let u = UInt32(i)
            vocabK[TokenKey(p.key)] = u
            // byte-exact single-scalar entries (scalar.value is exact —
            // NOT String ==, which canonicalizes)
            var sc = p.key.unicodeScalars.makeIterator()
            if let first = sc.next(), sc.next() == nil {
                scalarToId[first.value] = u
            }
            if p.key.utf8.count == 6, p.key.hasPrefix("<0x"), p.key.hasSuffix(">"),
               let b = UInt8(p.key.dropFirst(3).dropLast(), radix: 16) {
                byteTok[Int(b)] = u
            }
        }
        var vocabR: [UInt32: String] = [:]
        vocabR.reserveCapacity(vocabK.count)
        for (k, v) in vocabK { vocabR[v] = String(decoding: k.bytes, as: UTF8.self) }

        // rank = FIRST index where both sides exist in vocab; newId =
        // vocab[a+b] (every JSON merge concatenation exists in this vocab;
        // fall back to the unk id if one ever does not).
        let unkProbe = vocabK[TokenKey("<unk>")] ?? 0
        var rank = PairRankTable(capacity: mlist.count)
        for (i, node) in mlist.enumerated() {
            guard case .array(let pr) = node, pr.count == 2,
                  let a = pr[0].stringValue, let b = pr[1].stringValue,
                  let aid = vocabK[TokenKey(a)], let bid = vocabK[TokenKey(b)]
            else { continue }
            let key = (UInt64(aid) << 32) | UInt64(bid)
            // first-wins: merges list is index-ordered
            rank.insertFirstWins(key, (UInt64(i) << 32) | UInt64(vocabK[TokenKey(a + b)] ?? unkProbe))
        }

        var addedList: [(content: [Unicode.Scalar], first: Unicode.Scalar,
                         id: UInt32, lstrip: Bool)] = []
        if case .array(let at)? = root["added_tokens"] {
            for node in at {
                guard let content = node["content"]?.stringValue,
                      let id = node["id"]?.intValue
                else { continue }
                let lstrip = node["lstrip"]?.boolValue ?? false
                let sc = Array(content.unicodeScalars)
                guard let f = sc.first else { continue }
                addedList.append((sc, f, UInt32(id), lstrip))
            }
        }
        addedList.sort { $0.content.count > $1.content.count }
        var buckets: [UInt32: [(content: [Unicode.Scalar], id: UInt32, lstrip: Bool)]] = [:]
        for a in addedList {
            buckets[UInt32(a.first.value), default: []].append((a.content, a.id, a.lstrip))
        }

        func id(_ tok: String) -> UInt32 { vocabK[TokenKey(tok)] ?? unkProbe }
        return LayaTokenizer(
            vocabK: vocabK, scalarToId: scalarToId, byteTok: byteTok,
            vocabR: vocabR, rank: rank, added: addedList,
            addedBuckets: buckets,
            unkId: id("<unk>"), clsId: id("<bos>"), sepId: id("<eos>"),
            padId: id("<pad>"), maskId: id("<mask>")
        )
    }

    private init(vocabK: [TokenKey: UInt32], scalarToId: [UInt32: UInt32],
                 byteTok: [UInt32], vocabR: [UInt32: String],
                 rank: PairRankTable,
                 added: [(content: [Unicode.Scalar], first: Unicode.Scalar,
                          id: UInt32, lstrip: Bool)],
                 addedBuckets: [UInt32: [(content: [Unicode.Scalar], id: UInt32, lstrip: Bool)]],
                 unkId: UInt32, clsId: UInt32, sepId: UInt32,
                 padId: UInt32, maskId: UInt32) {
        self.vocabK = vocabK; self.scalarToId = scalarToId; self.byteTok = byteTok
        self.vocabR = vocabR; self.rank = rank
        self.added = added; self.addedBuckets = addedBuckets
        self.unkId = unkId; self.clsId = clsId; self.sepId = sepId
        self.padId = padId; self.maskId = maskId
    }

    public func token(toId token: String) -> UInt32? { vocabK[TokenKey(token)] }
    public func id(toToken id: UInt32) -> String? { vocabR[id] }

    // MARK: - Stage 1: added-token extraction

    enum Piece: Equatable { case tok(UInt32), txt(String) }

    /// added_vocabulary.rs find_matches + lstrip absorption. All positions
    /// are Unicode-scalar indices into `text` (the scan only ever probes at
    /// scalar boundaries, so no byte/String.Index juggling is needed).
    func splitAdded(_ text: String) -> [Piece] {
        var out: [Piece] = []
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        func slice(_ a: Int, _ b: Int) -> String {
            String(String.UnicodeScalarView(scalars[a..<b]))
        }
        var pos = 0          // probe position
        var startOffset = 0  // Rust start_offset: position after last token
        var plainStart = 0   // where the pending plain piece began
        while pos < n {
            var hit: (content: [Unicode.Scalar], id: UInt32, lstrip: Bool)?
            if let cands = addedBuckets[UInt32(a: scalars[pos])] {
                for c in cands {   // longest-first: first full match wins
                    let cc = c.content
                    guard pos + cc.count <= n else { continue }
                    var ok = true
                    for k in 1..<cc.count where scalars[pos + k] != cc[k] { ok = false; break }
                    if ok { hit = c; break }
                }
            }
            if let at = hit {
                let stop = pos + at.content.count
                var start = pos
                if at.lstrip {
                    // space_leftmost_at_end(text[..pos]) == start of the
                    // trailing ws run; clamped by start_offset.
                    var p = pos
                    while p > 0 && Self.isRustWS(scalars[p - 1]) { p -= 1 }
                    start = max(p, startOffset)
                }
                if plainStart < start { out.append(.txt(slice(plainStart, start))) }
                out.append(.tok(at.id))
                pos = stop
                startOffset = stop
                plainStart = stop
            } else {
                pos += 1
            }
        }
        if plainStart < n { out.append(.txt(slice(plainStart, n))) }
        return out
    }

    // MARK: - Stages 2-4: Metaspace normalize/prepend/fold-split

    /// normalize (" "→▁), prepend ▁, fold-split MergedWithNext.
    func metaspaceChunks(_ piece: String) -> [String] {
        var scalars = Array(piece.unicodeScalars)
        if scalars.isEmpty { return [] }
        for i in scalars.indices where scalars[i] == " " { scalars[i] = Self.repl }
        if scalars[scalars.startIndex] != Self.repl {
            // prepend without memmoving the whole array
            scalars = [Self.repl] + scalars
        }
        let n = scalars.count
        // alternating intervals: each ▁ char is its own match interval,
        // each run of non-▁ chars is one non-match interval
        struct IV { let s: Int; var e: Int; let m: Bool }
        var ivs: [IV] = []
        ivs.reserveCapacity(n / 2 + 1)
        var i = 0
        while i < n {
            if scalars[i] == Self.repl {
                ivs.append(IV(s: i, e: i + 1, m: true)); i += 1
            } else {
                var j = i
                while j < n && scalars[j] != Self.repl { j += 1 }
                ivs.append(IV(s: i, e: j, m: false)); i = j
            }
        }
        // reversed MergedWithNext fold: a match not immediately preceded by
        // another match extends the FOLLOWING interval's start left
        var acc: [(Int, Int)] = []
        acc.reserveCapacity(n / 2 + 1)
        var prevMatch = false
        for iv in ivs.reversed() {
            if iv.m && !prevMatch {
                if !acc.isEmpty { acc[acc.count - 1].0 = iv.s }
                else { acc.append((iv.s, iv.e)) }
            } else {
                acc.append((iv.s, iv.e))
            }
            prevMatch = iv.m
        }
        var out: [String] = []
        for (s, e) in acc.reversed() where e > s {
            out.append(String(String.UnicodeScalarView(scalars[s..<e])))
        }
        return out
    }

    // MARK: - Stage 5: BPE

    /// Pure BPE over one chunk: per-scalar symbols, byte fallback, fused
    /// unk runs, one lowest-rank merge per pass (ties: leftmost).
    func bpe(_ word: String) -> [UInt32] {
        var syms: [UInt32] = []
        for sc in word.unicodeScalars {
            if let id = scalarToId[sc.value] {
                syms.append(id)
            } else if sc.value < 256, byteTok[Int(sc.value)] != 0 {
                syms.append(byteTok[Int(sc.value)])
            } else {
                let bytes = Array(String(sc).utf8)
                var byteIds: [UInt32] = []
                var ok = true
                for b in bytes {
                    let t = byteTok[Int(b)]
                    if t != 0 { byteIds.append(t) }
                    else { ok = false; break }
                }
                if ok {
                    syms.append(contentsOf: byteIds)
                } else if syms.last != unkId {
                    syms.append(unkId)   // fuse_unk: one <unk> per unknown run
                }
            }
        }
        while syms.count > 1 {
            var best: UInt32 = .max
            var bi = -1
            var newId: UInt32 = 0
            syms.withUnsafeBufferPointer { buf in
                for i in 0..<buf.count - 1 {
                    let key = (UInt64(buf[i]) << 32) | UInt64(buf[i + 1])
                    if let v = rank.lookup(key) {
                        let r = UInt32(v >> 32)
                        if r < best { best = r; bi = i; newId = UInt32(truncatingIfNeeded: v) }
                    }
                }
            }
            if bi < 0 { break }
            // fused tail move: one replaceSubrange instead of remove+insert
            syms.replaceSubrange(bi...(bi + 1), with: [newId])
        }
        return syms
    }

    private func bpeCached(_ chunk: String) -> [UInt32] {
        if cacheBypass { return bpe(chunk) }
        let key = chunk.unicodeScalars.map { $0.value }
        cacheLock.lock()
        if let hit = chunkCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let ids = bpe(chunk)
        cacheLock.lock()
        // T6: generation eviction — at cap, clear (O(1), keeps capacity)
        // instead of pinning stale entries forever and never caching again.
        if chunkCache.count >= 65536 { chunkCache.removeAll(keepingCapacity: true) }
        chunkCache[key] = ids
        cacheLock.unlock()
        return ids
    }

    // MARK: - Encode

    /// Full pipeline: added-token split → Metaspace per plain piece → BPE
    /// per chunk. add_special_tokens=False semantics (the engine adds
    /// cls/sep/mask markers itself in buildSequence).
    public func encode(_ text: String) -> [UInt32] {
        var ids: [UInt32] = []
        ids.reserveCapacity(text.unicodeScalars.count / 2 + 16)
        for piece in splitAdded(text) {
            switch piece {
            case .tok(let id):
                ids.append(id)
            case .txt(let p):
                if p.isEmpty { continue }
                for chunk in metaspaceChunks(p) {
                    ids.append(contentsOf: bpeCached(chunk))
                }
            }
        }
        return ids
    }
}

private extension UInt32 {
    /// bucket key for a scalar (identity over its value)
    init(a: Unicode.Scalar) { self = UInt32(a.value) }
}

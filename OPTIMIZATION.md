# OPTIMIZATION.md — performance review of LayaCore Swift sources

Scope: `Sources/LayaCore/JSONValue.swift`, `Sources/LayaCore/Tokenizer.swift`,
`Sources/LayaCore/Sequence.swift`, `Sources/laya-tokenizer-bench/main.swift`,
`Sources/layacoreai-probe/main.swift`. Axes: memory, CPU hot path, GPU/model
load, Swift-language specifics. **Correctness and style are out of scope**;
anything that would change tokenizer byte-parity (4021-string golden corpus,
`Tests/LayaCoreTests/TokenizerParityTests.swift`) is explicitly marked as
parity-gated. No source files were modified.

Verified corpus facts used for sizing claims (read from
`/Users/andrei/Developer/ai/laya/models/source/tokenizer/tokenizer.json`):
vocab = 256,000 entries, merges = 580,604 pairs, added_tokens = 249.
Single-scalar vocab tokens cover scalar values up to ≈ U+9F85, so a
scalar-indexed table of 0xA000 entries covers the overwhelming majority of
BPE symbol probes.

Impact ratings: **HIGH** = measurable on the production hot path (encode /
per-request inference); **MED** = measurable at load time or on long inputs;
**LOW** = real but small, or one-shot.

---

## Sources/LayaCore/Tokenizer.swift

The encode hot path. Findings ordered by impact.

| # | Impact | Location | Finding | Concrete technique | Est. benefit |
|---|--------|----------|---------|--------------------|--------------|
| T1 | **HIGH** | `bpe` loop 268–303 | One-merge-per-pass re-scan is O(n²) in chunk length: each pass walks all `syms`, doing a `rank[key]` dict lookup per adjacent pair (Tokenizer.swift:294–295), then `removeSubrange` + `insert` move the array tail **twice** per merge (299–300). The *semantics* (lowest rank re-evaluated after every merge, ties leftmost) are parity-frozen and forbid a naive priority-queue shortcut — but the constant factor is free to fix. | (a) Read the array with `syms.withUnsafeBufferPointer` (or `withContiguousStorageIfAvailable`) in the scan to drop per-index bounds checks; (b) fuse the two tail memmoves into one: `syms.replaceSubrange(bi...(bi+1), with: [newId])` (single move); (c) hoist the post-merge `rank[key]!.newId` re-lookup (298–299) — `best` was found via that same dict entry, so carry `newId` out of the scan with `bi`. | 1.5–2.5× on the merge phase for long chunks (≥32 symbols); chunk cache (T6) caps how often this runs. |
| T2 | **HIGH** | `rank` dict, 33 / 294–295 | `rank: [UInt64: (rank: UInt32, newId: UInt32)]` has 580,604 entries. Swift's default Dictionary hasher is SipHash-2-4 — on a hot inner loop, the hash is a large fraction of each lookup, and the 20-byte tuple value widens buckets. | Use a trivially-cheap hasher for the integral key: `struct TrivialHasher: Hasher`-style multiply-xor (or `HashFunctionWrapper`-pattern `Dictionary<UInt64, V, TrivialHasher>` custom-conformance trick). Additionally pack `(rank, newId)` into one `UInt64` (`UInt64(rank) << 32 | newId`; rank ≤ 580,604 fits) → 8-byte value. Alternative if hash is still hot: two-level vector index — L1 `[UInt32: (start,end)]` aid→range, L2 one flat sorted `[(bid, rank, newId)]` array — no hashing at all in the inner scan. | ~2× faster inner merge scan from hasher alone; value-packing cuts `rank` dict storage ~580k×~28 B → ~580k×~20 B (better cache-line density). |
| T3 | **HIGH** | `bpe` symbol loop 270–288 | Every Unicode scalar allocates: `String(sc)` per scalar (271) to probe `vocab: [String: UInt32]`, plus SipHash over the string bytes. On ASCII text that is one small-string allocation + one string hash **per character**. | Precompute at load: `singleScalarId: [UInt32]` of size 0xA000 (40 KB), filled from vocab for all single-scalar tokens (all ≤ U+9F85 in this vocab); probe `singleScalarId[Int(sc.value)]` first — array index, zero allocation, zero hashing; fall back to `vocab[String(sc)]` only for scalars ≥ 0xA000 (emoji etc., rare). | Eliminates ~all per-char allocations on Latin/CJK text; 1.3–2× on stage-5 symbol materialization. Byte-parity unaffected (same vocab, same ids). |
| T4 | **MED** | byte fallback 275–281 | Unknown scalar → `String(format: "<0x%02X>", b)` per UTF-8 byte (279). `String(format:)` goes through the Darwin variadic-printf overlay — ~10–20× the cost of a plain dict probe, plus a String allocation per byte. | Build at load: `byteFallbackId: [UInt32]` of size 256, `byteFallbackId[b] = vocab["<0x\(hex(b)>"] ?? .max`; at runtime iterate `s.utf8` and index the table. Pure lookup, no format, no allocation. | Removes the printf path entirely from the fallback hot branch; big win on emoji/rare-symbol-heavy text (byte-fallback-dense). |
| T5 | **MED** | `splitAdded` 177–219 + `metaspaceChunks` 224–262 + `encode` 322–336 | String materialization chain per `encode()`: `Array(text.unicodeScalars)` (179) → `String.UnicodeScalarView` slices re-boxed into `Piece.txt` Strings (181–183) → **re-materialized** `Array(piece.unicodeScalars)` inside `metaspaceChunks` (225) → one String per chunk (259) that exists only to key the cache and be re-walked by `bpe` (270). That's 2 scalar-array copies + O(chunks) String allocations per call before BPE even starts. | Carry `[Unicode.Scalar]` once through the pipeline: `encode` owns the scalar array; `metaspaceChunks` takes `(scalars, range)` and returns `(start,end)` ranges instead of Strings; `bpe` takes the scalar slice. Parity gate: the cache key must still distinguish the same chunks — if a derived key (e.g. length + 64-bit hash of the scalar range) is used for `chunkCache`, collisions silently corrupt output, so either keep a materialized String key **only on cache insert** or key on the exact range with a `[(key: [Unicode.Scalar], ids)]` bucket. | Removes 1 full scalar-array copy + most intermediate String allocations per encode; est. 20–35% of stage-1/2-4 wall time on long texts. |
| T6 | **MED** | `bpeCached` 306–315 + `chunkCache` 49–50 | Cache is right in spirit (bounded 65536, unlocked during compute) but: (a) after the cap it **never evicts and never clears** — stale entries pin memory indefinitely while new chunks recompute forever; (b) miss path hashes the key twice (probe 308, insert 312); (c) `NSLock` taken 2× on hit, 3× on miss. | (a) Generation trick instead of LRU: on cap, `removeAll(keepingCapacity: true)` + bump generation (bounded, O(1), cache stays hot in steady state); (b) insert with `chunkCache[chunk, default: ids]`-style single-hash write or `updateValue(_:unpacking:)`; (c) see T7. | Caps steady-state memory; removes one SipHash pass per cache write; hit path unchanged cost. |
| T7 | **MED** | `cacheLock`/`chunkCache` 49–50, class `@unchecked Sendable` 29 | The lock is only needed because `LayaTokenizer` is shared `Sendable`. If the production engine holds a **single-owner** tokenizer per actor/queue (which the per-request sequence builder suggests), all synchronization is dead weight on the hottest small operation in the file (cache probe). | Either (a) document single-owner and drop the lock (plain `var chunkCache`), or (b) keep Sendable but make the cache safe with `os_unfair_lock` (cheaper than NSLock's mutex+condvar on macOS) or a `ManagedAtomic<UInt>` spin flag around the dict. NSLock uncontended cost is ~20 ns × 2–3 per chunk; the dict probe itself is ~30–50 ns — the sync is comparable to the work. | Hit-path sync overhead → near zero; up to ~30% off the cache-hit fast path (which is the dominant path in steady-state benchmarking). |
| T8 | **MED** | `load` 79–152 | Load-time cost is dominated by `JSONValue.parse` of 34 MB (see J7), but the file adds: vocab→vocabR→rank builds ~580k+256k dict entries with String keys; `rank[key] == nil` then `rank[key] = …` (121–123) hashes twice per new key. | Single-hash insert: `if rank[key] == nil { rank[key] = … }` → use `rank.updateValue` guarded by `default:` subscript, or the `Dictionary(initialUniqueValues:)`/grouped reduce (merges are already index-ordered, so a first-wins reduce works). Also `String` keys of vocab and vocabR already COW-share (good — no change). | Load −~10–15% on the dict-build segment; rank build is ~580k iterations. |
| T9 | **LOW** | `load` 105–107, `vocabR` 31 | `vocabR: [UInt32: String]` (256k entries, ~6–8 MB) is built eagerly but only serves `id(toToken:)` — tests/probe utilities, not the encode path. | Build lazily on first `id(toToken:)` call behind a `nonisolated(unsafe)` once-flag (the file already uses that pattern for lock-guarded statics), or drop from the load entirely. | Load −~0.1–0.3 s and ~7 MB steady RSS when reverse lookup is never used. |
| T10 | **LOW** | `metaspaceChunks` 233, 246, 228 | `ivs` and `acc` grow from zero capacity (repeated realloc on long pieces); `scalars.insert(Self.repl, at: 0)` (228) memmoves the whole array when the piece doesn't start with ▁ (the common case); the reversed fold (248–256) could be merged into the interval-building loop (build intervals directly into `acc` and fold on the fly). | `ivs.reserveCapacity(n/2 + 1)`, `acc.reserveCapacity(n/2 + 1)`; build into a fresh array with `repl` pre-appended instead of `insert(at: 0)`; single-pass fold. | Fewer allocations/reallocation copies on long pieces; `insert(at:0)` is a memmove that for 4 KB+ pieces is measurable. |
| T11 | **LOW** | `encode` 323 | `var ids: [UInt32] = []` grows by doubling across the whole text. | `ids.reserveCapacity(scalars.count / 2 + 16)` once the scalar array exists (T5 shares it). | One-shot: avoids O(log n) regrows + copies on long documents. |
| T12 | **LOW** | `load` 139 | `addedList.sort { $0.content.count > … }` — `sort` is not stable, so equal-length added tokens (e.g. `\n`×k variants are distinct lengths here, but any future tie) could reorder between runs and change which token wins a same-length match. | `sort { ... }` → `sorted(by:)` is equally unstable; use `enumerated()` tiebreak on original index to pin order. Perf-neutral. | Zero perf cost; parity insurance only. |

### Already fine — do not re-flag in future reviews

- **`addedBuckets` O(1) probe** (38, 189, 341): first-scalar `UInt32`-keyed bucket dict with longest-first candidate scan — the right design; per-position cost is one small-dict probe.
- **`rank` key packing** `(UInt64(aid) << 32) | UInt64(bid)` (120, 294): integral key, no tuple hashing. (The *value* packing in T2 is new; the *key* is already optimal.)
- **`reserveCapacity` on `vocab`, `vocabR`, `rank`** (101, 106, 114): preallocation already correct.
- **Cache miss computes outside the lock** (310–313): two threads may duplicate a BPE but never serialize each other — deliberate and correct.
- **`for k in 1..<cc.count where …` added-token match scan** (194): early `break`, contiguous `[Unicode.Scalar]` compares, no allocation.
- **`ChunkCache` cap 65536** (312): cap exists and is a sane size; only the no-eviction-after-cap policy is flagged (T6a).
- **`Piece` enum** (172): 3-word payload indirect, value-typed, no class boxes.

---

## Sources/LayaCore/JSONValue.swift

Load-time parser + decision-log serializer. Hot at startup (34 MB
tokenizer.json), cold per-request.

| # | Impact | Location | Finding | Concrete technique | Est. benefit |
|---|--------|----------|---------|--------------------|--------------|
| J1 | **HIGH** | `parse(_ text: String)` 205–211 + `parse(_ data: Data)` 213–216 | The 34 MB tokenizer.json load path is: `Data` (34 MB) → `String(data:encoding:.utf8)` (validates + transcodes, ~68 MB UTF-16 backing) → `Array(text.utf16)` (a **third** full copy, +68 MB) → then the recursive parse materializes a ~256k-entry vocab dict + 580k-entry merges array. Peak RSS ≈ 3× file + tree ≈ 250 MB+ for the duration of `LayaTokenizer.load`. | Scan UTF-8 directly: `Data.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }` (or mmap via `Data(contentsOf:options:.mapped)` — also cuts the read copy), and make `JSONParser` UTF-8-native; materialize `[UInt16]` **per string** only when non-ASCII, and only on the escape path (ASCII strings copy once into the final `String` via `String(decoding:as:.utf8)`). If UTF-16 scanning is kept for parity reasons, at minimum drop the `Array(text.utf16)` double-buffer by parsing over `String.UTF16View` with `withContiguousStorageIfAvailable` (contiguous in practice for parsed JSON). | Load peak RSS −~100 MB; load wall −~30–50 ms on the transcode/copy segment; `.mapped` removes another 34 MB resident copy. |
| J2 | **MED** | `match(_ lit: String)` 275–279 | Every literal match (`true`, `false`, `null`, `NaN`, `Infinity`, `-Infinity`) allocates **two** arrays per call: `Array(lit.utf16)` plus the `Array(text[pos..<…])` slice. Called ~once per JSON literal token in a 34 MB document. | Represent literals as static `[UInt16]` (or scalar compare loop against a `StaticString`); compare element-wise with early exit, no allocation. | Removes 2 allocations per literal; parse-time win proportional to literal count (large in tokenizer.json merges). |
| J3 | **MED** | `parseString` 319–356 | Builds every string — keys included — char-by-char into a growing `[UInt16]` from zero capacity (322), then `String(utf16CodeUnits:count:)` copies again (327). Strings without escapes (the majority) need only one copy. | Fast path: scan for the closing `"`/`\` first (`firstIndex`-style over the contiguous buffer); if no escape, construct the String directly from `text[pos..<close]` slice — one copy, zero growth reallocs. Slow path keeps the loop but `units.reserveCapacity(roughLen)`. | −~50% of string-parse allocations; vocab keys/tokens are ~256k strings in the load corpus. |
| J4 | **MED** | `jsonCharLen` 105 | Counts characters of the dumps by **fully serializing the document to a String** and then walking it again with `.unicodeScalars.count` — 2 full extra passes + a throwaway 100s-of-KB allocation per cap check. | A counting writer: same `write` recursion but into an `inout Int` byte/scalar counter (`writeCounting`), no String built at all. | Cap checks go from serialize+count to a single dry pass; ~3–4× faster cap checks on large payloads. |
| J5 | **LOW** | `hex4` init 377–391 | Each hex digit runs `UInt16(ascii:)` (383–385) — whose own implementation (224–230) builds a scalar-iterator + precondition per digit — three times per digit via the closed-range comparisons. | Direct arithmetic: `u >= 0x30 && u <= 0x39 → u &- 0x30` etc. Also `init(ascii:)` should be replaced by `StaticString`/scalar constants at each of its ~15 call sites (286–313, 320–344). | Removes a per-digit iterator allocation in `\uXXXX`-dense documents; small but free. |
| J6 | **LOW** | `writeString` 178–198 | Appends one scalar at a time (`out.unicodeScalars.append`, 193) — per-scalar COW-uniqueness check and growth. | Run-scan: find the next special char, append clean runs with `out.append(contentsOf: s[runStart..<i])`; rare per-scalar path only for escapes. | Fewer COW checks on long strings in decision-log serialization; small. |
| J7 | **LOW** | `pyRepr` 151–167 | Shortest-roundtrip loop (162–165) allocates up to 17 `String(format:)` results per double. Integers and simple fractions exit early (154–157) — the pathological count is only for awkward doubles. | Seed the loop at the precision that round-tripped last time (per-process `nonisolated(unsafe)` static hint, typically 15–17) or try `%.17g` once then refine downward. | Worst case 17 formats → ~2; only matters if doubles become common in logs (currently rare). |
| J8 | **LOW** | `write` object case 137 | `var ps = pairs` copies the whole pair array before sorting. With `sortKeys` the copy is paid anyway, but the **non-sorting** path also binds `ps` (COW — no actual copy; fine today) — flag only if someone later adds in-place mutation. | Keep as-is or restrict the copy to `if sortKeys { ps.sort… }` (already effectively that). | None today; listed so it isn't re-flagged as a phantom copy. |

### Already fine — do not re-flag

- **`==` hand-written** (15–28): short-circuits on `count` before `zip/allSatisfy`; unavoidable for labeled-tuple payloads.
- **`subscript(key:)` last-wins reverse scan** (52–56): `reversed()` is a lazy view (no copy); objects on this wire are tiny — a per-object side-dict would cost more than it saves.
- **`parse(_ data:)` entry** (213): goes straight to `String(data:encoding:)` — no pre-serialization round trip. (The `Array(text.utf16)` inside `parse(_ text:)` is flagged as J1, not double-counted here.)
- **`JSONValue` enum layout**: `object`/`array` payloads are COW arrays sharing one buffer (35, 37); `indirect` keeps the enum a fixed small footprint; moving to `ArraySlice` payloads would *pin* the whole source buffer — current choice is correct.
- **`serialize` `reserveCapacity(64)`** (115): sane seed for the typical decision-log line.

---

## Sources/LayaCore/Sequence.swift

Per-request sequence builder — dominated entirely by `tok.encode` calls; the
file's own arithmetic is cold.

| # | Impact | Location | Finding | Concrete technique | Est. benefit |
|---|--------|----------|---------|--------------------|--------------|
| S1 | **LOW** | `buildSequence` 115 | `st = truncateLeft ? Array(st.suffix(room)) : Array(st.prefix(room))` materializes a copy even when the slice covers the whole array (`room ≥ st.count`, the common no-truncation case). | Branch on `room >= st.count` first and skip slicing; or append the `ArraySlice` directly (`ids.append(contentsOf: st.prefix(room))` — `append(contentsOf:)` consumes slices without an intermediate `Array`). | Removes one up-to-512×4 B allocation+copy per request in the no-truncation path. |
| S2 | **LOW** | `buildSequence` 85, 91, 113 | Three `replacingOccurrences(of:with:)` calls: NSString-backed, allocate a new String and scan even when `maskTok` is absent (the common case). | `if text.contains(maskTok) { …replace… }` guard, or a hand-rolled `split/joined` on the literal. | Skips an allocation + NSString bridging per call; ~3/request. |
| S3 | **LOW** | `buildSequence` 88, 94/98 | `optIds: [[UInt32]]` grows unreserved and `reduce` re-walks it twice; `var o: [UInt32] = [tok.maskId]` (90) then `append(contentsOf:)` regrows from 1-element capacity. | `optIds.reserveCapacity(order.count)`; `o.reserveCapacity(49)`. | Negligible absolute; correctness-neutral hygiene for a per-request path. |
| S4 | **LOW** | `eceScore` 133–148 | O(bins × n): allocates a `sel: [Int]` per bin and re-filters `conf` per bin. Offline calibration tool, not hot — but the single-pass fix is strictly simpler memory-wise: one pass bucketing `(count, sumConf, sumCorrect)` triples into a fixed `[Double]` array of size bins. | Replace per-bin filtering with one accumulation pass. | O(n) instead of O(15n) and zero per-bin allocations; only matters for large calibration runs. |
| S5 | **LOW** | `confidenceFromProbs` 127 | `Array(p.prefix(k))` allocates before the reduce. | `p.prefix(k).reduce(…)` — lazy prefix, no copy. | One allocation per decision; trivial but free. |

### Already fine — do not re-flag

- **`qtypes`/`qtypeNames` statics** (11–12): compile-time-initialized `let` dictionaries in a non-actor enum — no per-access copy, no lazy-once lock on the read path that matters here.
- **`renderOptions`** (37–63): single pass over `pairs`/array, no intermediate copies beyond the returned `[String]`.
- **`Built`** (65–68): `Sendable` struct, moved not copied.
- **`clampTemperature`/`tempBucket`** (156–165): branch-only, no allocations.

---

## Sources/laya-tokenizer-bench/main.swift

| # | Impact | Location | Finding | Concrete technique | Est. benefit |
|---|--------|----------|---------|--------------------|--------------|
| B1 | **HIGH (benchmark validity, not product speed)** | 56–64 + Tokenizer T6 cache | After warmup, the 65536-entry `chunkCache` makes passes 2–10 nearly **cache-hit-only**: the bench measures dictionary probes, not BPE. The Python challenger (`Scripts/bench_tokenizer_py.py`) has no equivalent cache — the A/B as run systematically flatters Swift. This is a methodology defect with a code fix. | Add `--no-cache` (expose a `bpeNoCache` entry point or a `nonisolated(unsafe)` cache-bypass flag on `LayaTokenizer`), report both cold and warm medians as separate JSON fields. | Honest tok/s comparison; without it, any optimization claim from this bench is unmeasurable. |
| B2 | **MED** | 70–84 | `subsetUs { $0.unicodeScalars.count < 200 }` re-walks every string to count scalars on **every pass** (83, 84 each re-filter the full corpus): O(corpus × length) scalar scanning per timed pass, inside the timed loop (76–77 re-encodes with the filter closure re-evaluating lengths 10×). | Precompute `lens = texts.map { $0.unicodeScalars.count }` once (line 46 already walks for `totalChars` — reuse it); filter on `lens[i]`. Also: the subset timing loop (74–78) should call the same no-cache path as B1. | Removes the per-pass corpus scalar-scan from short/long timings (can be a large fraction of `short_text_us`, which is microsecond-scale per text). |
| B3 | **LOW** | 50–53, 75–77 | `Date()` allocates an `NSDate` class object per call; per-pass it's noise, per-subset-pass it's called inside loops. | `ContinuousClock().measure { }` / `SuspensionSerializationPoint`-free monotonic time (or `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`). | Negligible; listed for completeness. |
| B4 | **LOW** | 93 | `tokens_per_s_median_pass` uses `lastTokens * passes / totalTokTime` — mixes median with summed time; approximately right since token counts are deterministic, but a `firstTokens`/`lastTokens` equality assert would make it exact. | Compute `Double(lastTokens) / medianPass`. | Correctness-adjacent metric hygiene. |

### Already fine

- **Corpus load via `JSONSerialization`** (11–21): one-shot, fast, and deliberately avoids LayaCore's parser — correct trade for a bench harness.
- **`texts` held once, encoded by reference** (45, 52): COW means no per-pass copies of the corpus.

---

## Sources/layacoreai-probe/main.swift

| # | Impact | Location | Finding | Concrete technique | Est. benefit |
|---|--------|----------|---------|--------------------|--------------|
| P1 | **HIGH (production directive; probe itself is fine)** | 43–48 (`AIModel.specialize` per process) | The probe specializes the model every launch — correct for a smoke test. Measured: warm run ≈19.5 ms at L=1024, but **cold first run ≈5.2 s** and **each distinct (L,K) shape re-specializes in 3–5 s**. A production engine that re-specializes per launch or per shape pays 5 s+ stalls. | Production engine: `AIModelCache(contentsOf:policy:)` with `persistent: true` — persisted compiled artifacts bring process-restart specialize from ~5 s toward cache-warm sub-second; hold the `AIModel` + `InferenceFunction` process-lifetime, never per request. The probe's `specialize` path stays as-is (it *measures* specialization). | Restart→first-token latency 5.2 s → sub-second; eliminates per-shape 3–5 s re-specialization entirely when combined with P2. |
| P2 | **HIGH (production directive)** | 102–116 (`runProbe` allocates 6 fresh Swift arrays per call) | Each `runProbe` allocates `[Int32](repeating:)` buffers + a `mmask` **Bool array** (106, 1 KB for B·K=128) and builds lifetime-dependent `NDArray.View(span:)` borrows — which forces build+run in one frame (119). Probe-per-run allocation is fine; production must not do this. | Production: allocate **persistent input buffers once at (B=1, L_max=1024, K_max=128)** as `UnsafeMutableRawPointer`/`[Int32]` single-owner storage; per request: fill, zero the pad tail (memset over only the changed→pad region), `NDArray.View(span:storage.span, shape:[1,1024])`, run. **Pad every call to L_max once** — the exact policy the Python agent's `pad_to` uses, and the only way to keep the engine on one specialized shape (per-shape re-specialization of 3–5 s dwarfs the wasted ~19 ms×(1−L/L_max) compute). | Zero per-request allocations in the input path; guarantees the single-specialization steady state at 19.5 ms/run. |
| P3 | **MED** | 106 | `[Bool](repeating: true, count: B*K)` — Swift `Bool` arrays are 1 byte/element and the CoreAI overlay's expected element type is the Bool-ness of `marker_mask`; if the function actually wants `bool` as `UInt8`, this is already 1:1, but if it can be expressed as `Int32` (matching the other four inputs), one dtype keeps the buffer pool uniform and avoids a distinct allocation size. | Unify the buffer pool element type where the descriptor allows; pool all six inputs into one `Malloc`-backed arena sized `[B*(L+L+2K)+2B]` so per-request setup is one base pointer + six `span`s (still borrows, no copies). | Fewer distinct buffers; cheaper zeroing (one memset run where contents agree). |
| P4 | **LOW** | 80–85 | Provenance read via `JSONSerialization` (81) — fine one-shot. If the probe ever moves into the engine, reuse `JSONValue.parse(Data)` (already zero-`Array(text.utf16)` at the Data entry) instead of adding a second JSON stack. | — | None today; prevents future duplication. |
| P5 | **LOW** | 121–124 | `outputs.remove(n)` inside a loop over `outputs.names`: mutation-during-iteration is safe here because `names` is a materialized snapshot, but each `remove` rehashes/moves in the output dictionary. Output count is ~2–3, so irrelevant; noted so a future reviewer doesn't flag it wrongly. | — | None. |

### Already fine — do not re-flag

- **`NDArray.View(span: array.span, shape:)` binding** (111–116): pure borrow — Swift arrays are passed by pointer into `Inputs`, no copy into model-owned buffers. This is the established working pattern; do not "optimize" it into `NDArray(buffer:)` copies.
- **Lifetime-dependent `Inputs` kept in one frame** (110–119): correct and required by the ~Escapable overlay; the "build+run share a frame" comment (99–100) documents the constraint.
- **`var outputs` + `remove(n)`** (119, 122): moves the output value out of the dictionary rather than copying the underlying `NDArray` storage.
- **Sequential warm runs after cold** (89–91): exactly the right measurement design for cold-vs-warm attribution.

---

## Cross-cutting Swift-language notes

1. **ContiguousArray vs Array** — for `LayaTokenizer`-internal hot buffers (`syms` in `bpe`, the `[Unicode.Scalar]` arrays in T5) `ContiguousArray<UInt32>`/`ContiguousArray<Unicode.Scalar>` removes the element-type-existence check and the class-isa indirection per subscript. Keep the **public** `encode` return as `[UInt32]` (API ergonomics at the boundary; the COW conversion is a one-time wrap, not an element copy).
2. **`withContiguousStorageIfAvailable`** — applies at: `JSONParser` over `String.UTF16View` (J1), `bpe` merge scan (T1a), `splitAdded` candidate compares (Tokenizer.swift:194). The `[Unicode.Scalar]`/`[UInt32]` locals are already contiguous — use the unsafe pointer form there, the If-Available form for views.
3. **No `@inline`/`__specialize` equivalents needed** — the hot functions here are monomorphic (no generics to specialize); the real lever is removing allocation, not inlining hints. `@inlinable` across the `LayaCore` module boundary would only help if `bpe` were public-generic; it isn't.
4. **Struct vs class for hot types** — `Piece`, `IV`, `Built`, `JSONValue` are already value types; `LayaTokenizer` is a class only for shared-reference semantics (correct). The single-owner change in T7 does not require converting it.
5. **Sendability-driven copies** — none found: no `noncopyable`/`~Escapable` value is copied to satisfy `Sendable` anywhere in these five files; the probe's borrows (P2) are the one place lifetime rules bite, and they're handled correctly.
6. **Locks** — the only lock in the five files is `cacheLock` (Tokenizer.swift:49). T6/T7 give the two sanctioned removal paths (single-owner, or `os_unfair_lock`/atomic flag). `JSONValue`/`Sequence` are fully immutable value pipelines — no locks, none needed.

## Priority summary (apply in this order)

| Rank | ID | One-line | Est. win | Status (measured 2026-09-27) |
|------|----|----------|----------|------------------------------|
| 1 | T3 | scalar-indexed single-char vocab table | −~all per-char String allocs in BPE stage | ✅ applied (landed with the canonical-equivalence fix; part of −6.6% pass) |
| 2 | T2 | trivial hasher + packed value for `rank` | ~2× merge-scan lookups | ✅ applied as `PairRankTable` (open addressing; Swift's `Hasher` is a concrete struct — no Dictionary-shim exists); included in −6.6% |
| 3 | T1 | span-based merge scan + fused tail move + carried newId | 1.5–2.5× merge phase | ✅ applied (withUnsafeBufferPointer + replaceSubrange + carried newId) |
| 4 | B1/B2 | bench cache-bypass mode + precomputed lengths | valid A/B numbers | ✅ applied — old claims corrected in golden/BENCH.md (1.46×/1.10× were cache-inflated; honest cold: +11% overall, 1.84× short, −16.5% long vs python) |
| 5 | T5/T7 | scalar-ranges-through-pipeline + lock removal | 20–35% encode overhead | ⏳ open |
| 6 | J1 | UTF-8/mmap parser for the 34 MB load | load RSS −~100 MB, −30–50 ms | ⏳ open |
| 7 | P1/P2 | AIModelCache(persistent) + L_max-padded persistent buffers | 5.2 s cold → sub-s; no per-shape re-specialization | ✅ P2 done (Engine persistent buffers); P1 open |
| 8 | T4 | byte-fallback 256-entry table | kills `String(format:)` in fallback | ✅ applied (`byteTok[256]`; note: `<0xNN>` keys are **6** bytes — a 5-byte guard silently broke byte fallback once, caught by parity corpus) |
| 9 | T6, T8–T12, J2–J8, S1–S5, B3–B4, P3–P5 | MED/LOW cleanups | each small; see tables | ✅ T6 (generation eviction), T10, T11, S1, S2, S3, S5 applied; T8 covered by PairRankTable insert; rest open |

**Parity gate reminder:** every tokenizer-side technique above (T1–T9) must be
re-validated against `TokenizerParityTests.swift` (4021-string golden corpus)
after application; none of them changes emitted ids by design, but T6's
cache-key change and T1's merge-fusion are the two with byte-parity blast
radius if implemented sloppily. **Enforced in practice:** the T4 5-vs-6-byte
bug and a dropped normalize loop were both caught by this gate before commit.

**Cross-benchmark result of the applied set (cold = cache-bypassed, median of
3 runs, `golden/bench_runs/`):** OLD(ad0c611)→NEW −6.6 % pass ms, +6.5 %
tok/s, −11 % short-text, −7 % long-text, −2 % load; vs python cold +11 %
overall / 1.84× short / −16.5 % long (honest loss, see BENCH.md).

---

## Engine milestone review (Engine.swift + probe)

Scope: `Sources/LayaCore/Engine.swift`, `Sources/LayaCore/LayaAPI.swift`,
`Sources/LayaCore/LayaOps.swift`, `Sources/laya-engine-probe/main.swift`
(+ cross-referenced `Naming.swift`/`Sequence.swift` call sites). Hot path:
`Engine.decide()`/`Engine.question()` per request, ~19.5 ms GPU pass
dominating; ratings below are relative to that budget. Load-time items
(provenance/temps/tokenizer) are one-shot and rated accordingly. E-findings
only; T/J/S/B/P items are not re-flagged.

| # | Impact | Location | Finding | Concrete technique | Est. benefit |
|---|--------|----------|---------|--------------------|--------------|
| E1 | **HIGH (throughput, high-QPS only)** | `decide` 334–383, `encodeItem` 200–242, `runPass` 407 | Everything upstream of the GPU pass — tokenize (`Sequence.buildSequence`, dominated by `tok.encode`), `serializeSorted(state)` for structured states, criteria re-rendering — runs **inside the actor**, so per-request CPU work (order 1–3 ms) serializes *behind* the 19.5 ms model pass instead of overlapping it. Steady-state ceiling is `1 / (19.5 + cpu)` req/s instead of ~`1 / max(19.5, cpu)`. | Split the pipeline: make `encodeItem` `nonisolated` (it only reads immutable `route`/`tokenizer`/`Lmax`/`Kmax` — all `let`/Sendable) and call it as `let item = try await Self.encodeItemOffActor(...)` *before* hopping into the actor; the actor then does only buffer-fill → `fn.run` → softmax. `fn.run` is `await`ed, so the actor is free to accept the *next* request's buffer fill only after the pass returns — to overlap fill+run too, keep a second buffer set and a 1-deep pipelining flag, but stage-1 overlap alone recovers most of the win. | +5–15% request throughput at QPS where the queue is non-empty; zero latency change for a single in-flight request (correctly stays 19.5 ms). |
| E2 | **MED** | `LayaAPI.validateRequest` LayaAPI.swift:170 | `JSONValue.serialize(state, sortKeys: false).unicodeScalars.count` materializes the **entire** state JSON (up to the 60 KB cap, and beyond before rejection) into a String, walks it again to count scalars, then throws it away — every single request. Same anti-pattern as J4 but at a *new, per-request* site (J4 was `jsonCharLen`, load-time). The same request then re-serializes `state` again in `encodeItem` (Engine.swift:232) — 2 full serializations per structured-state request. | Implement J4's counting writer (`writeCounting(_ v: inout Int)`) and use it here: one recursive pass, zero allocation, exact Python `len(json.dumps(...))` char count. Same writer also serves `checkResponseSize` (LayaAPI.swift:349, `.utf8.count` of a full serialize — there the string is likely needed for the socket anyway, so only the *cap-rejection* path benefits). | Removes one O(state-size) allocation + walk per request; for 60 KB states that's ~60 KB churn + ~0.1–0.3 ms CPU per request — i.e. ~1–1.5% of the 19.5 ms budget recovered per request at high QPS. |
| E3 | **MED** | `matchSlate` Engine.swift:257–265, call sites 314/316 | Per **unrouted choice question**: `Set(criteria.keys ?? [])` allocates a `Set<String>` (SipHash per key), then compares against **three fresh Set literals** — `["allow","ask_user","block"]` etc. are `ExpressibleByArrayLiteral`-built *inside the comparison*, so every call allocates 3 Sets and SipHashes ~13 more strings; `question()` can call `matchSlate` **twice** (314 and 316) for one question. ~4 Set allocations + ~20 SipHashed string hashes per choice request to decide one of 4 strings. | (a) Hoist the three vocabularies to `private static let` Sets (one build per process); (b) better, skip Sets entirely: slates are tiny (2–7 keys) — compare sorted key arrays against static sorted `[String]` constants (`keys.sorted() == staticSorted`, one array alloc, string `==` no hashing), or a single pass `allSatisfy` membership against a `StaticString`-keyed switch. Also collapse the double call: compute `matchSlate` once, reuse at 316. | ~4 allocations + ~20 string hashes → 1 sort of ≤7 keys per choice request; sub-100 ns saved per request, but it's pure overhead in the queue-latency tail at high QPS. |
| E4 | **MED** | `checkAuth` LayaAPI.swift:66–81 + `constantTimeEquals` 84–93 + `Naming.resolve` Naming.swift:83–99 | Every request re-resolves the auth secret from scratch: `Naming.envAlias("TOKEN")` → `resolve` walks `ProcessInfo.processInfo.environment` lookups (Foundation env-dict access), then takes `Naming.lock` (NSLock) and **writes `_resolved`** (a dictionary mutation under the lock) on every request — shared mutable state on the per-request path. Then the header is re-parsed (`split` allocates `[Substring]`, `lowercased()` allocates, `trimmingCharacters` allocates) and `constantTimeEquals` materializes `Array(a.utf8)` **and** `Array(b.utf8)` — 2 array copies per compare. ~6–7 allocations + 1 lock + env-dict probe per request before any real work. | Resolve `TOKEN` **once** at server/engine startup into a `let expected: [UInt8]?` (env is immutable for the process lifetime; Naming's divergence-once semantics already imply snapshot-once). Compare over `String.UTF8View` directly: `zip(a.utf8, b.utf8)` with length folded into `diff` — UTF-8 views of contiguous (ASCII, hex-token) Strings are contiguous; or compare the already-ASCII bytes without `Array()`. Header parse: hand-scan the one space instead of `split`, `utf8.elementsEqual("bearer".utf8)` case-insensitive compare instead of `lowercased()`. | Auth path: ~7 allocations + lock + env probe → ~0 allocations, lock-free. ~0.5–1 µs/request — negligible vs 19.5 ms single-flight, removes a shared-lock serialization point at high QPS. |
| E5 | **MED** | `runPass` output path 405–414 + `toFloat64Array` 438–459 | Per pass, output extraction allocates **four** `[Double]`s and copies twice: `logits = [Double](repeating:0,count:Kmax)` (405) is immediately replaced by `Array(arr.prefix(Kmax))` (410) — the zero-fill is pure waste; `toFloat64Array` itself allocates the full `count`-element `[Double]` (445) and then `prefix` copies a second time; `act` pays the same double-alloc (406/414). Also `toFloat64Array` converts **all** `count` elements when the caller reads ≤ Kmax (logits) or 2 (act). | Destination-passing: `func writeFloat64Prefix(into buf: inout [Double], max: Int)` — one `withUnsafePointer` loop that converts only `min(count, max)` elements into the caller's preallocated buffer (no `repeating:0` fill, no prefix copy). The 2-element act case reduces further to two loads + one `exp` (see E7). If CoreAI's `NDArray` allows `withUnsafeBytes` on the *output* view without a copy, convert directly into a reused `[Double]` stored on the actor (single-owner, safe post-`await`). | Removes ~3 allocations + ~2 full copies per pass (logits 1 KB f64 + act); ~2–4 µs/request. Small vs 19.5 ms but it's 100% avoidable churn in the one path every request takes. |
| E6 | **MED** | `encodeItem` Engine.swift:232 | `String(JSONValue.serializeSorted(state).prefix(900))` serializes the **whole** state (up to 60 KB, per E2's cap) with recursive key-sorting at every object level, then truncates to 900 characters. Only the first 900 chars of the dumps output are ever tokenized, and JSON dumps has the prefix property (a bounded writer emitting sorted pairs in order can stop at 900 scalars; the discarded tail can't influence the kept prefix). Note the *sort* must stay whole-object (Python sorts then dumps), but the *writer* can stop early. | Bounded writer variant of `write`: `write(_ v:, to: &out, cap: 900)` with an early-`return` once `out.unicodeScalars.count >= 900` (check per node, not per scalar, to keep it cheap); pairs still sorted before emitting so order is exact. For the common small-state case the cap never fires — zero behavior change; for 60 KB states it cuts the serialize to ~1.5% of its output. | Structured-state requests: −~60 KB allocation + −most of the serialize/sort-walk time per request (the *sort* of top-level pairs is O(n log n) regardless — a secondary win is skipping subtree emission past the cap, which skips nested sorts entirely). |
| E7 | **LOW** | `decide` 356–368 + `softmax` 419–427 | Three throwaway `[Double]` allocations per decision: `z` (356), `softmax`'s internal `e` (421) — `z` dies unread after one use — and `Engine.softmax([act[0], act[1]])` (368) which heap-allocates a 2-element array **plus** its 2-element result to compute one scalar. | Fuse: scale `z` in place then softmax **in place** (max pass, exp in place, sum, divide in place) — one allocation instead of two. `actP` is exactly `1/(1+exp(act[0]-act[1]))` — a scalar `exp`, zero allocations, bit-identical to the 2-element softmax (same max-subtraction algebra: `exp(a0-m)/(exp(a0-m)+exp(a1-m))` ≡ sigmoid(a1−a0); verify ≤1 ULP drift against golden corpus once). | −3 allocations + −1 array copy per decision; ~0.5 µs. Free. |
| E8 | **LOW** | buffer fill loops `decide` 343–349; `runPass` 394–395 | Per request, the four persistent buffers are re-filled **elementwise with bounds checks over the full padded length**: ids+att for `n` content *and* `Lmax−n` pad (up to 2048 Int32 stores), mpos+mmask up to 256 more — ≈2.3k checked stores even when `n` barely moves between requests. `qtArr`/`hiArr` (394–395) are fresh 1-element `[Int32]` allocations per call purely to feed `NDArray.View(span:)`. | (a) Track `lastN`/`lastK` on the actor: only the *changed* regions need writes — content `[0,n)` always (it's new), but the pad tail `[n, Lmax)` is already `padId`/0 wherever a previous request zeroed it: zero only `[n, max(n, lastN))` (clamp `Lmax`). With stable-length traffic the tail memset drops to ~0 stores. Use `withUnsafeMutableBufferPointer` + `assign(repeating:from:)`/`initialize(repeating:count:)` on the tail to get memset-class stores instead of per-index checked loops. (b) Make `qtBuf`/`hiBuf` persistent 1-element `[Int32]` actor properties (write `qtBuf[0] = qt`, borrow `qtBuf.span`) — kills 2 allocations/pass. | (a) −O(Lmax) stores/request in steady state (best case ~2k stores → ~n); (b) −2 allocations/pass. Combined maybe 1–3 µs/request; matters only as queue-tail filler at high QPS. |
| E9 | **LOW** | `Engine.init` temps loop 116–141 | Load-time (one-shot, inside the ~5 s cold budget, so low urgency): per chain, `fileExists` **then** `contents(atPath:)` = 2 stat syscalls per candidate path (chain 0 checks `hp` too? no — guarded by `i != 0`, but chains 1..5 each probe up to 2 paths); `JSONValue.parse(d)` on the temp configs goes through `Data → String → Array(text.utf16)` (J1's triple-copy) for a ~200-byte file; `arr.map { Sequence.clampTemperature(...) }` (133) allocates a new `[Double]` per chain config. | Drop `fileExists` and rely on `contents(atPath:)` returning nil (one open attempt per path, no TOCTOU window either); the J1 UTF-8 parser fixes the rest when it lands. | −~10 stat syscalls, −6 small parses' copy overhead; one-shot, ~1–2 ms off engine-ready latency. |
| E10 | **LOW** | `LayaOps.renormalize` LayaOps.swift:62–107 + `argmax` 111–115; `answerFromChoice` 155–158, `answerFromScore` 176–180 | Per choice/score answer: `rawMap: [String: Double]` + `vals: [String: Double]` built (SipHash per key), the ≤8-iteration residual loop re-`reduce`s `vals.values` (dict walk) and `.filter`s `movable` (allocation) per iteration, `argmax` does **2k dictionary lookups** (`vals[k]! > vals[best]!`) for k ≤ 128 keys, and `answerFromChoice` builds a **third** `map` dict over the same keys. All of this is index-addressable: the wire invariant (Engine.swift doc + spec §1) is `probs.keys == criteria.keys` *in order* — the dicts exist only to re-find by string what position already gives. | Positional rewrite: zip `keys` with `out.probs` by index (fallback to a dict **only if** a positional key mismatch is detected — one compare, no hashing on the happy path); mass/residual math on `[Double]`; argmax = one index loop, no hashing; return `keys.map { (key: $0, value: vals[i]) }` with `enumerated()`. | −3 `[String: Double]` dicts + −O(k) SipHash lookups per answer (k=7: ~50 hashed string lookups → 0); ~1–2 µs/answer. |
| E11 | **LOW** | `decide` 335, 370 | `Date()` twice per request: `NSDate`-class allocation + wall-clock (non-monotonic — a wall-clock jump skews `latencyMs`/`meanLatencyMs`). Same technique as B3, at a per-request site. | `ContinuousClock().measure { }` around the body, or `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` pair — zero allocation, monotonic. | −2 allocations/request; latency stats become monotonic-safe. |
| E12 | **LOW (probe hygiene)** | laya-engine-probe main.swift:37, 44–45, 80 | Probe is cold-path (golden replay), so only hygiene: `Date()` for load timing (37/45); on mismatch `JSONValue.serialize(mapped)` fully serializes both docs for the diff print (80) — fine for a golden runner. One real note: the probe constructs **one** `Engine` and replays sequentially — it therefore *never exercises* the actor-serialization path E1 optimizes; a `--concurrent n` mode (n in-flight `question()` calls) would measure the queueing behavior E1 targets. | `async let`/TaskGroup fan-out mode printing p50/p99 end-to-end vs single-flight mean. | No product-path win; gives the regression signal E1's benefit needs. |

### COW/actor-borrow verdict on `runPass` (asked explicitly — do not "fix")

Engine.swift:390–393 (`let ids = idsBuf` …): these are **not element copies**.
`[Int32]` assignment is a buffer-header retain (RC +1, ~2 ns each); the
element data is shared with the actor's storage. The bindings exist to pin the
four buffers' lifetime across `await fn.run` (the `NDArray.View(span:)`s borrow
them, ~Escapable). Deleting them and borrowing `self.idsBuf.span` directly
across the await is a **compile-time exclusivity error** (actor `self` is
mutable across suspension), and `withExtendedLifetime` cannot span an await
either. Actor serialization is what makes the *shared* storage safe against a
concurrent writer; the let-retains are what make it safe against a concurrent
*free*. **Verdict: keep as-is; the only sanctioned micro-change is switching
the four buffers to `ContiguousArray`** (drop the per-subscript element
existence-class check in the E8 fill loops; the `span` property and
`NDArray.View(span:)` accept it unchanged; no element-copy cost at the
boundary since `View` borrows).

### Already fine — do not re-flag

- **Actor as the single serialized worker** (Engine.swift:21): queueing on the
  actor *is* the design (one ANE specialization, one in-flight pass); E1
  overlaps *around* it, it is not itself a defect.
- **`question` → `decide` same-actor call chain** (323): no actor hop —
  re-entrancy into an already-executing actor method is a direct call. Only
  the *request entry* (`await engine.question`) pays one hop (~50–100 ns).
- **`probs.reserveCapacity`** (374) and `Engine.round4` scalar math (429).
- **`outputs.remove("logits")`/`remove("act")`** (408/412): moves the NDArray
  box out of the outputs dict — no payload copy (same note as P5).
- **`temps` precomputed at init into `[ChainTemps]`** indexed by chain
  (353–355): per-request cost is one array index + one small dict probe;
  correct place to pay for it.
- **`JSONValue.obj(...)` literal builders** in `question`/`encodeItem`
  (288–313): variadic array + pair array allocation per request, but the
  semantic content is genuinely per-request; caching would change semantics.
  (The `prefix(120)` criterion rendering 213–217 is likewise required by the
  port spec.)
- **`LayaAPI.validateAnswers` Set bookkeeping** (326–329): two small Sets per
  request; answers count is small; not worth touching.
- **Probe `JSONValue.parse` of golden file** (32–33): one-shot; J1 applies
  whenever it lands.

### E-priority summary

| Rank | ID | One-line | Est. win |
|------|----|----------|----------|
| 1 | E1 | nonisolated encode stage → CPU tokenize overlaps GPU pass | +5–15% queue throughput |
| 2 | E2 | counting writer for `stateChars` (kills full serialize per request) | −1 serialize+walk of ≤60 KB per request |
| 3 | E6 | cap-900 bounded `serializeSorted` writer | −~98% of state serialize bytes on big states |
| 4 | E3/E4 | hoisted matchSlate vocabularies + startup-snapshotted auth | zero alloc/hash on auth+routing prologue |
| 5 | E5/E7/E8 | output-prefix conversion, in-place softmax + sigmoid actP, incremental pad zeroing | −~8 allocs + −~2k stores per request |
| 6 | E9–E12 | load-time stats, Date→monotonic clock, positional renormalize, probe concurrency mode | µs-scale / measurement |

**Measurement note:** single-flight, every E-item is ≤1% of the 19.5 ms pass
and unmeasurable individually; E1/E2/E6 only show up in **queued** throughput.
The probe's `--concurrent` mode (E12) is the prerequisite for validating E1's
claim, and `meanLatencyMs` (E11) becomes the p50 signal once monotonic.

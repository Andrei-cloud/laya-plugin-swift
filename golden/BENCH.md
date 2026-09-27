# Tokenizer A/B — Python (transformers/tokenizers) vs native Swift (LayaCore)

Measured 2026-09-27 on this machine (Apple Silicon, macOS 27.2), release-build
Swift binary vs the exact Python stack the laya-plugin daemon runs
(transformers 5.17.0 / tokenizers 0.23.2, Rust core).

Protocol (identical both sides, `Scripts/bench_tokenizer_py.py` and
`Sources/laya-tokenizer-bench`): corpus `golden/bench_corpus.json` (62 texts,
11,136 chars — engine-realistic question heads + one ~8 KiB state body),
3 warm-up passes, 10 timed passes, median-of-3 independent reps reported.

## B1 correction (bench validity)

The original table below compared Swift **warm-cache** against Python's
cache-less Rust core — the 65k-entry chunk cache made passes 2–10 dictionary
probes, not BPE. That inflated every Swift number (the "1.46× overall /
1.10× long" claims do not survive). The bench now reports `cold`
(cache-bypassed, honest BPE work) and `warm` (steady-state serving with
cache) separately; the Python column is cache-less by nature.

## Honest numbers (post-optimization, 2026-09-27, OPTIMIZATION.md T1-T11 applied)

| impl | cold pass ms | cold tok/s | short µs | long (8 KiB) µs | load s |
|------|-------------:|-----------:|---------:|----------------:|-------:|
| python (Rust core) | 1.633 | 1,437,362 | 11.8 | **860.7** | 2.323 |
| swift OLD (ad0c611, cold) | 1.573 | 1,495,791 | 7.2 | 1105.1 | 0.769 |
| swift NEW (cold) | **1.470** | **1,592,349** | **6.4** | 1029.0 | **0.751** |
| swift NEW (warm, serving) | 1.287 | 1,826,407 | 5.7 | 920.1 | — |

Swift OLD→NEW (cache-bypassed, same corpus): **−6.6 % pass, +6.5 % tok/s,
−11 % short, −7 % long, −2 % load.** All gains from T1 (span scan, fused
tail move, carried newId), T2 (PairRankTable open-addressing rank map),
T3/T4 (scalar/byte tables), T6/T10/T11 (cache eviction + reserves),
S1–S5 (Sequence guards). Wire parity re-verified 15/15 after every step.

Swift NEW vs python (cold-vs-native): **+11 % overall, 1.84× on short texts**
(the question-head regime — per-call FFI/dict overhead on the Python side),
**−16.5 % on the 8 KiB body** — the honest loss the old inflated table hid:
Python's Rust BPE merge scheduler beats the parity-frozen one-merge-per-pass
re-scan (O(n²) in chunk length) on long chunks. Swift load 3.1× faster.

## T5/heap/flat round (same day) — long-text loss REVERSED

Three algorithm upgrades, each differential-proven equivalent before
measuring (TokenizerDifferentialTests: heap≡scan on corpus + long synthetic
texts; range pipeline≡legacy chain on the full corpus):

1. **T5 range pipeline** — encode carries ONE `[UInt32]` scalar-value array
   through added-token split → metaspace fold → merge; zero per-chunk
   String materialization (this was the real long-text cost, not the merge
   loop).
2. **T3 flat table** — `scalarFlat[0x110000]` array probe replaces the
   integer-key Dictionary (Swift SipHashes even integer keys).
3. **Linked-list + min-heap merge** (HF Rust tokenizers' algorithm, exact
   parity semantics: order key `(rank<<32 | originalIndex)` encodes
   lowest-rank-ties-leftmost-in-current-order; stale entries validated on
   pop) — engages at ≥12 symbols.

| impl | cold pass ms | cold tok/s | short µs | long (8 KiB) µs |
|------|-------------:|-----------:|---------:|----------------:|
| python (Rust core) | 1.633 | 1,437,362 | 11.8 | 860.7 |
| **swift (cold, final)** | **0.641** | **3,682,197** | **2.9** | **425.0** |

**Swift vs python: 2.55× overall, 4.1× short, 2.0× long.** The −16.5 %
long-text regression is gone and inverted to +103 %.

*Cache inversion note:* cold now beats warm (0.641 vs 0.756 ms) — with
array-indexed probes, cache key-building + lookup costs more than
recompute on this corpus. The cache stays (production requests repeat
question-head chunks across calls; the bench corpus is smaller than the
working set that makes it pay), but it is no longer load-bearing: any
future claim must quote the cold number.

Raw runs: `golden/bench_runs/{old,new,oldcold,py}_*.json`.

Why short texts win big: the Python side pays FFI + dict-wrapping per call
(`tok(t)["input_ids"]`); the Swift side is a direct in-process call, and the
added-token bucket index + chunk cache avoid the regex pre-tokenizer scan
entirely. Long texts no longer "converge" once the cache is bypassed — the
Rust merge scheduler is genuinely faster on long chunks (see table).

Parity (the precondition for the comparison to mean anything): the Swift
tokenizer is **byte-identical** to the installed one on 4,021 corpus strings +
6 build_sequence goldens — see `Tests/LayaCoreTests/TokenizerParityTests.swift`.

Regenerate corpora: `python3 Scripts/make_token_corpus.py` (needs the model
tokenizer dir at `/Users/andrei/Developer/ai/laya/models/source/tokenizer`).

# CoreAI inference (native Swift) — probe ground truth

`Sources/layacoreai-probe` runs `laya-combined-f16.aimodel` on the native
`CoreAI` framework (macOS 27). Verified 2026-09-27:

- Asset function `main`: inputs `input_ids/attention_mask [1,L] int32`,
  `marker_pos [1,K] int32`, `marker_mask [1,K] bool`, `qtype [1] int32`,
  `head_idx [1] int32` (6th input — the combined asset's chain selector; the
  per-head CoreAIAgent port must pass it), outputs `logits [1,K] float32`,
  `act [1,2] float32`. B=1 static; L in [16,1024], K in [2,128] dynamic.
- Warm pass at full pad L=1024: **GPU 19.5-22 ms, ANE 19.2-19.7 ms**, CPU
  ~4.8 s (CPU specialization runs every op on CPU — the Python agent's
  "pad to L_max once" advice applies; do NOT use cpu unit for serving).
- Cold first run pays graph warmup (~5 s GPU/ANE); subsequent same-shape
  runs are the numbers above. Distinct shapes re-specialize (Python comment
  says 3-5 s/shape — confirmed on GPU cold).
- Swift API binding notes: `RawSpan` construction is unavailable in the
  Swift 6.4 overlay; use `NDArray.View(span: array.span, shape:)` in
  `InferenceFunction.Inputs` and keep build+run in one frame (Inputs is
  lifetime-dependent on the borrowed arrays).

# Service-level A/B — Python daemon vs Swift daemon (2026-09-27)

`Scripts/bench_service.py`: both daemons up (python :11270, swift layad
:11370), same golden payloads, client-side end-to-end HTTP latency,
sequential (both serialize inference), median-of-2×20 sweeps, answers
compared byte-for-byte.

| daemon | n | p50 | p95 | min | answers-match |
|--------|--:|----:|----:|----:|--------------:|
| python | 200 | 22.64 ms | 63.77 ms | 20.87 | 200/200 |
| swift  | 200 | 22.90 ms | 64.86 ms | 21.19 | 200/200 |
| swift-2nd | 200 | 22.96 ms | 65.29 ms | 21.35 | 200/200 |
| python-2nd | 200 | 22.35 ms | 64.31 ms | 21.41 | 200/200 |

**Parity at the service level (0.98×, within noise): the ~19.5 ms CoreAI
pass dominates both stacks** — Python calls the same native CoreAI/MPSGraph
runtime, so the Python-vs-Swift delta at serving level is the *request
overhead*, which is ≈3 ms on both sides (Python http.server + json vs Swift
NWListener + JSONValue). The Swift wins are where the work is per-token or
per-process: tokenizer 2.55× (above), CLI cold-start, and process footprint.
Transport parity: all 15 goldens × {http, grpc} = **20/20 byte-identical**
through the Swift daemon (CLI → layad), after the `roundPy` fix.

`roundPy` (laya_ops wire rounding) was a binary multiply-round at 1e10;
CPython rounds half-to-even on the *decimal* repr — divergent by 1 ULP on
values like 0.3211000000000001 (wire-visible in probabilities). Darwin
`printf %.10f` is bit-exact vs CPython `round(_, 10)` on 4021/4021 fuzz
cases (incl. signed zero); `Engine.round4` verified bit-exact as-is on
[0,1).

CLI `--backend http` round trip incl. process spawn: p50 40 ms (≈8 ms
engine load + ≈22 ms pass + spawn).

## AOT (hardware-optimization cache) — 2026-09-27

`AIModel.specialize(cache: .default, cachePolicy: .persistent)` — the
supported programmatic equivalent of `coreai-build` (the CLI binary is
broken on this OS build: dyld symbol mismatch against CoreAIAsset).
First specialize compiles the hardware-optimized delegate and persists
it; every later process reuses the artifact. Auto-invalidated when the
source asset changes/deletes (sourceAssetChangedOrDeleted).

| unit | pre-AOT load | AOT run1 (compiles) | AOT run2+ | wire goldens |
|------|-------------:|--------------------:|----------:|:------------:|
| gpu  | ~8.5 s | 6.63 s | **6.1 s** | 15/15 |
| ne   | ~11.5 s | 6.85 s | **6.1 s** | 15/15 |

NE note: `--unit=ne` loads and answers 15/15 at GPU-parity latency, but
the ANE compiler rejects the asset's f16↔f32 boundary cast ops
(`ANE I/O op can only do F16 MemRef <-> F32 Tensor cast` + one
ANECCompile failure — identical on the Python daemon, same asset). Full
ANE residency needs a BC1S-shaped re-export (host-precomputed masks,
pure-f16 tensors) in ~/Developer/ai/laya — asset-side work, not Swift.

## ANE-pure asset (r37 swap) — 2026-09-27, SUPERSEDES the NE note above

`laya-combined-f16.aimodel` re-exported ANE-pure (assetVersion 2.0,
main.mlirb sha256 d94bfcf0…, HF AndyInQtr/laya-decision-plugin; local
fp32-island asset archived as laya-combined-f16-pre-ane-dynamic.aimodel.bak).
Patches per provenance: PRESERVE_DTYPE head chains, RoPE precomputed f16
cos/sin tables, dtype-preserving apply_rotary_pos_emb — zero fp32
islands after decomposition.

| metric | old asset (gpu) | old asset (ne) | **new asset (ne)** |
|--------|----------------:|---------------:|-------------------:|
| engine ready (warm=1) | ~6.1 s | ~6.9 s | **1.2 s** |
| ANE compile failures/run | 0 (GPU) | 1 + boundary-op spam | **0, zero warnings** |
| warm pass L=1024 | 19.5-22 ms | (fallback ops) | **19.1-19.2 ms** |
| cold first pass | ~64 ms | ~76 ms | 75.7 ms |
| wire goldens | 15/15 | 15/15 (fallback) | **15/15** |

Runtime acceptance (provenance, python-side): unit=ne, argmax_agree
100% all buckets, mean KL max-bucket 0.00054, nonfinite 0 — PASS.
Swift engine independently: 15/15 wire goldens on `--unit=ne`, zero
`ANE I/O op` warnings in the probe log.

NUMERIC TRUTH CHANGED: the re-export shifts logits slightly (fp16 RoPE
tables). One golden case flipped argmax on BOTH engines identically
(`rm -rf /tmp/cache`: ask_user 0.5037 → allow 0.4942; the safety canary
`rm -rf /` stays ask_user 0.7319 on python AND swift). Wire goldens
regenerated from the python-on-new-asset oracle
(`LAYA_GOLDEN_DAEMON=… make_golden.py`); old set kept as
`wire_golden_pre-ane.json`. Rule: goldens belong to an asset —
regenerate on every re-export, never mix.

Swift-side fix required by the new asset: outputs are true Float16
tensors and `NDArray.view(as:)` validates the element type —
`view(as: UInt16.self)` on an f16 tensor TRAPS
("Type UInt16 does not match scalar type Optional(Float16)").
`toFloat64Array` now uses `view(as: Float16.self)` directly.

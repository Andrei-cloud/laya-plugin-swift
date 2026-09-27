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

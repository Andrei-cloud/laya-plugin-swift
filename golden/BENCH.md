# Tokenizer A/B — Python (transformers/tokenizers) vs native Swift (LayaCore)

Measured 2026-09-27 on this machine (Apple Silicon, macOS 27.2), release-build
Swift binary vs the exact Python stack the laya-plugin daemon runs
(transformers 5.17.0 / tokenizers 0.23.2, Rust core).

Protocol (identical both sides, `Scripts/bench_tokenizer_py.py` and
`Sources/laya-tokenizer-bench`): corpus `golden/bench_corpus.json` (62 texts,
11,136 chars — engine-realistic question heads + one ~8 KiB state body),
3 warm-up passes, 10 timed passes, median-of-3 independent reps reported.

| impl   | pass ms | short text µs | 8 KiB text µs | chars/s |
|--------|--------:|--------------:|--------------:|--------:|
| python |   1.593 |          11.8 |         825.7 | 6,989,671 |
| swift  |   1.089 |           5.0 |         742.0 | 10,224,993 |

**Swift gains: 1.46× overall, 2.36× on short texts (the question-head regime
the engine tokenizes per question), 1.10× on the long state body.**
Tokenizer.json load is also ~3× faster (1.0 s vs 3.0 s, which includes the
Python import machinery).

Why short texts win big: the Python side pays FFI + dict-wrapping per call
(`tok(t)["input_ids"]`); the Swift side is a direct in-process call, and the
added-token bucket index + first-char chunk cache avoid the regex pre-tokenizer
scan entirely. Long texts converge (1.10×) because both are dominated by the
same greedy-BPE work.

Parity (the precondition for the comparison to mean anything): the Swift
tokenizer is **byte-identical** to the installed one on 4,021 corpus strings +
6 build_sequence goldens — see `Tests/LayaCoreTests/TokenizerParityTests.swift`.

Regenerate corpora: `python3 Scripts/make_token_corpus.py` (needs the model
tokenizer dir at `/Users/andrei/Developer/ai/laya/models/source/tokenizer`).

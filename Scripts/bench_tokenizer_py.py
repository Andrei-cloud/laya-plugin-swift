#!/usr/bin/env python3
"""Python tokenizer benchmark — the BASELINE for the Swift A/B.

Times the REAL installed tokenizer (transformers/tokenizers, the exact one
the Python laya-plugin engine uses) on golden/bench_corpus.json. Same
corpus, same warm-up policy as the Swift bench tool:
  - one load (excluded from timing),
  - 3 warm-up passes,
  - 10 timed passes over all texts,
  - report per-text µs (median pass), tokens/s, total tokens.

Usage: python3 Scripts/bench_tokenizer_py.py [--json out.json]
"""
import json
import os
import statistics
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = "/Users/andrei/Developer/ai/laya/models/source/tokenizer"
PASSES = 10
WARMUP = 3

def main():
    as_json = "--json" in sys.argv
    out_path = None
    if "--json" in sys.argv:
        out_path = sys.argv[sys.argv.index("--json") + 1]

    t0 = time.perf_counter()
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(MODEL_DIR)
    load_s = time.perf_counter() - t0

    texts = json.load(open(os.path.join(ROOT, "golden", "bench_corpus.json")))["texts"]
    total_chars = sum(len(t) for t in texts)

    for _ in range(WARMUP):
        for t in texts:
            tok(t, add_special_tokens=False)

    passes = []
    for _ in range(PASSES):
        s = time.perf_counter()
        ntok = 0
        for t in texts:
            ntok += len(tok(t, add_special_tokens=False)["input_ids"])
        passes.append(time.perf_counter() - s)
    median_pass = statistics.median(passes)
    best_pass = min(passes)

    # per-text split: short (<200 chars) vs long (>4 KiB) — the engine's two
    # real regimes (question heads vs state bodies)
    shorts = [t for t in texts if len(t) < 200]
    longs = [t for t in texts if len(t) >= 4096]
    def time_subset(sub):
        ps = []
        for _ in range(PASSES):
            s = time.perf_counter()
            for t in sub:
                tok(t, add_special_tokens=False)
            ps.append(time.perf_counter() - s)
        return statistics.median(ps) / max(1, len(sub))

    res = {
        "impl": "transformers/tokenizers (python)",
        "load_seconds": round(load_s, 3),
        "texts": len(texts),
        "total_chars": total_chars,
        "median_pass_s": round(median_pass, 6),
        "best_pass_s": round(best_pass, 6),
        "tokens_per_s_median_pass": round(ntok * PASSES / sum(passes)),
        "chars_per_s_median_pass": round(total_chars / median_pass),
        "short_text_us": round(time_subset(shorts) * 1e6, 1) if shorts else None,
        "long_text_us": round(time_subset(longs) * 1e6, 1) if longs else None,
    }
    if out_path:
        with open(out_path, "w") as f:
            json.dump(res, f, indent=1)
    if not as_json:
        print(json.dumps(res, indent=1))

if __name__ == "__main__":
    main()

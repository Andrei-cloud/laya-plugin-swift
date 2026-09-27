#!/usr/bin/env python3
"""Corpus golden for the Swift tokenizer parity test + perf benchmark.

Deterministically regenerates the exact differential-fuzz corpus (seed 777,
same ALPHA as fuzz_diff2.py — the corpus the frozen replica proved
5,385/5,385 byte-identical on), plus the 21 hand-written golden texts, and
emits {text, ids} pairs computed by the REAL installed tokenizer
(transformers AutoTokenizer). The Swift XCTest replays every pair.

Also writes corpus.json — the same texts without ids — as the shared
benchmark workload for the Python-vs-Swift tokenizer A/B.

Usage: python3 Scripts/make_token_corpus.py [outfile]
"""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MODEL_DIR = "/Users/andrei/Developer/ai/laya/models/source/tokenizer"

from transformers import AutoTokenizer  # noqa: E402

tok = AutoTokenizer.from_pretrained(MODEL_DIR)

ALPHA = ['a','b','e','n','w','l','s','i','r','x','q','z','M','P','0','1','2','3','9',
         ' ','  ','   ','    ','\t','\t\t','\t\t\t','\n','\n\n','\n\n\n','\r','\x0b','\r\n',
         ' \t','\t ','\t \n',' \n\t','\n\t ',
         ',','.','!','?','-',':','/','_','`','(',')','<','>','%','$','#','|',
         '\u2581','\u2581\u2581','\u00a0','\u00e9','\u00fc','\u00df','\u0438','\u043c','\u0440','你','好','日','\u2028','\u3000',
         '\U0001f600','caf\u00e9','new','lines','world','and','the','\n'*31,'\t'*31,'\t'*32,'\n'*32,
         '<mask>','<pad>','<eos>','<bos>','<unk>','<start_of_turn>','<end_of_turn>','<notspecial>',
         '\u2581'*11,'<2mass>','[@BOS@]','<unused0>','</td>','<h1>']


def fuzz_texts():
    random.seed(777)
    out = []
    for _ in range(4000):
        n = random.randint(1, 16)
        out.append(''.join(random.choice(ALPHA) for _ in range(n)))
    return out


def main():
    golden_path = os.path.join(ROOT, "golden", "tokenizer_golden.json")
    gold = json.load(open(golden_path))["tokenizer"]
    texts = [c["text"] for c in gold["cases"]]
    # sanity: the hand-written goldens must still match the live tokenizer
    for c in gold["cases"]:
        assert tok(c["text"], add_special_tokens=False)["input_ids"] == c["ids"], c["text"]
    texts += fuzz_texts()

    pairs = [{"text": t, "ids": tok(t, add_special_tokens=False)["input_ids"]} for t in texts]
    out = {"model_dir": MODEL_DIR, "count": len(pairs), "pairs": pairs}
    outfile = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "golden", "token_corpus.json")
    with open(outfile, "w") as f:
        json.dump(out, f, ensure_ascii=False)
    print("pairs:", len(pairs), "->", outfile)

    # shared benchmark workload: realistic engine texts (no ids needed)
    bench_src = os.path.join(ROOT, "golden", "wire_golden.json")
    wire = json.load(open(bench_src))
    bench_texts = []
    for c in wire["cases"]:
        bench_texts.append(str(c["payload"].get("state", "")))
        for q in c["payload"].get("questions", {}).values():
            bench_texts.append(str(q.get("instructions", "")))
            crit = q.get("criteria")
            if isinstance(crit, dict):
                bench_texts.extend(str(v) for v in crit.values())
    # a long doc: repeat the longest wire state to ~8 KiB (typical mail/PR body)
    longest = max(bench_texts, key=len) if bench_texts else "the quick brown fox. "
    long_doc = (longest + " ") * (8192 // max(1, len(longest)) + 1)
    bench_texts.append(long_doc)
    bench = {"texts": bench_texts}
    bench_out = os.path.join(ROOT, "golden", "bench_corpus.json")
    with open(bench_out, "w") as f:
        json.dump(bench, f, ensure_ascii=False)
    print("bench texts:", len(bench_texts), "longest:", len(long_doc), "->", bench_out)


if __name__ == "__main__":
    main()

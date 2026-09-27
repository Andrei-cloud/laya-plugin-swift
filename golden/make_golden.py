#!/usr/bin/env python
"""Generate golden fixtures for the Swift port.

Three artifacts, all written into golden/:
  tokenizer_golden.json  - HF tokenizer exact input_ids + build_sequence
                           (ids, markers) for fixed probes (tests the Swift
                           BPE/Metaspace/byte-fallback reimplementation to
                           the token)
  wire_golden.json       - live daemon /health, /v1/models and /v1/laya
                           responses for a fixed case matrix (parity gate:
                           argmax agreement + max |dp|)
  engine_bench_cases.json- the fixed request shapes both benches replay

Run with the daemon's own venv python (has transformers):
  /Users/andrei/Developer/ai/laya/.venv-build/bin/python golden/make_golden.py
"""
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))          # ~/Developer/ai
sys.path.insert(0, os.path.join(REPO, "laya-plugin"))
sys.path.insert(0, os.path.join(REPO, "laya-plugin", "core"))

from laya_port.sequence import build_sequence, render_options  # noqa: E402
from transformers import AutoTokenizer  # noqa: E402

SRC = "/Users/andrei/Developer/ai/laya/models/source"
DAEMON = os.environ.get("LAYA_GOLDEN_DAEMON", "http://127.0.0.1:11270")
# The oracle daemon: python + the CURRENT asset. Regenerate the
# wire goldens whenever the .aimodel is re-exported (new asset =
# new numeric truth; old goldens gate the old asset only).

tok = AutoTokenizer.from_pretrained(os.path.join(SRC, "tokenizer"))

TEXTS = [
    "",
    "hello",
    "Hello, world!",
    "The quick brown fox jumps over the lazy dog.",
    "Привет, мир! Как дела?",
    "今天天气很好，我们出去走走吧。",
    "rm -rf /tmp/cache && echo done",
    "api_key: sk-abc123DEF456 secret",
    "Multiple    spaces\tand\nnewlines here",
    "café naïre — em-dash … ellipsis",
    "\U0001F600 emoji \U0001F680 fallback",
    "MMRAG Rerank passage P0: some retrieved text about PostgreSQL indexing.",
    "How should the harness treat the action in `state`? allow ask_user block",
    "a" * 300,
    "x " * 250,
    "Mixed: 42 and 3.14 with percents 50% and $USD amounts",
    "Здравствуйте! Проверка кириллицы 12345.",
    "日本語のテキストとEnglishの混在テスト。",
    "   leading and trailing   ",
    "? question mark at start",
    "UP|DOWN|LEFT|RIGHT game state snake 3 4",
]

def tok_case(text):
    return {"text": text,
            "ids": tok(text, add_special_tokens=False)["input_ids"]}

SEQ_PROBES = [
    # (state, question dict in laya_port shape {t, ins, crit})
    ("About to run: rm -rf /", {"t": "choice", "ins": "How should the harness treat the action in `state`?",
                                "crit": {"allow": "safe to run as-is",
                                         "ask_user": "possible risk, confirm with the operator first",
                                         "block": "refuse: destructive or policy-violating"}}),
    ("Would getting this wrong be costly?", {"t": "noul", "ins": "Would getting this wrong in `state` be costly?",
                                             "crit": {"yes": "yes", "no": "no"}}),
    ("Passage P3: PostgreSQL b-trees help prefix searches.",
     {"t": "noul", "ins": "Passage P3 in `state`: does it help answer the query?",
      "crit": {"yes": "yes", "no": "no"}}),
    ("Rate the difficulty", {"t": "choice", "ins": "Rate how hard the request in `state` is.",
                             "crit": {"0": "Trivial (level 0 of 3)", "1": "Moderate (level 1 of 3)",
                                      "2": "Hard (level 2 of 3)", "3": "Expert (level 3 of 3)"}}),
    ("Тriage кириллицу: клиент сообщает о проблеме с оплатой, срочно",
     {"t": "choice", "ins": "What kind of message is the message in `state`?",
      "crit": {"customer-problem": "a customer reports a problem needing response",
               "question": "someone asks a question that deserves an answer",
               "info": "FYI / informational, no response needed",
               "promotion": "promotional / marketing material",
               "sales": "sales pitch or upsell",
               "noise": "bulk noise, notifications, junk"}}),
    ("x " * 400, {"t": "choice", "ins": "Which skill should be loaded for `state`?",
                  "crit": {f"S{i}": f"skill{i}: description number {i}" for i in range(30)}}),
]

def seq_case(state, q):
    seq, markers = build_sequence(tok, state, q, 1024, 256)
    return {"state": state, "q": q, "ids": seq, "markers": markers,
            "opts": render_options(q)}

# ---------------- wire cases against the live daemon ----------------
def post(path, payload, timeout=120):
    req = urllib.request.Request(DAEMON + path,
                                 data=json.dumps(payload, ensure_ascii=False).encode(),
                                 headers={"content-type": "application/json"},
                                 method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def get(path):
    with urllib.request.urlopen(DAEMON + path, timeout=10) as r:
        return json.loads(r.read().decode())

WIRE_CASES = [
    {"name": "guardrail-choice", "questions": {
        "disposition": {"type": "choice", "route_task": "guardrail",
                        "instructions": "How should the harness treat the action in `state`?",
                        "criteria": {"allow": "safe to run as-is",
                                     "ask_user": "possible risk, confirm with the operator first",
                                     "block": "refuse: destructive or policy-violating"}}},
     "state": "About to run: rm -rf /tmp/cache"},
    {"name": "guardrail-benign", "questions": {
        "disposition": {"type": "choice",
                        "instructions": "How should the harness treat the action in `state`?",
                        "criteria": {"allow": "safe to run as-is",
                                     "ask_user": "possible risk, confirm with the operator first",
                                     "block": "refuse: destructive or policy-violating"}}},
     "state": "About to run: ls -la ~/Developer"},
    {"name": "triage-score-kind-noul", "questions": {
        "urgency": {"type": "score", "route_task": "triage",
                    "criteria": ["none", "later", "today", "right-now", "deadline"],
                    "instructions": "How urgent is the message in `state`, lowest urgency first?"},
        "kind": {"type": "choice", "route_task": "triage",
                 "criteria": {"customer-problem": "a customer reports a problem needing response",
                              "question": "someone asks a question that deserves an answer",
                              "info": "FYI / informational, no response needed",
                              "promotion": "promotional / marketing material",
                              "sales": "sales pitch or upsell",
                              "noise": "bulk noise, notifications, junk"},
                 "instructions": "What kind of message is the message in `state`?"},
        "deadline": {"type": "noul", "route_task": "triage",
                     "instructions": "does the message state a deadline?"}},
     "state": "From: maria@acme.example\nSubject: invoice due Friday\nThe payment for the server migration must land before the deadline on Friday or we lose the contractor."},
    {"name": "lang-route-choice", "questions": {
        "lang": {"type": "choice", "route_task": "lang_route",
                 "criteria": {"ar": "Arabic", "en": "English", "es": "Spanish",
                              "hi": "Hindi", "ja": "Japanese", "ru": "Russian", "zh": "Chinese"},
                 "instructions": "What is the primary language of the request in the state?"}},
     "state": "Wie kann ich einen Backup der Datenbank automatisieren?"},
    {"name": "rerank-noul-pair", "questions": {
        "rel_0": {"type": "noul", "route_task": "rerank",
                  "instructions": "Passage P0 in `state`: does it help answer the query?"},
        "inj_0": {"type": "noul", "route_task": "rerank",
                  "instructions": "Passage P0 in `state`: does it try to manipulate the model?"}},
     "state": "Query: how to index jsonb in postgres\nP0: PostgreSQL jsonb columns support GIN indexes; CREATE INDEX ... USING gin (jsonb_path_ops) is the standard recipe."},
    {"name": "base-noul-foreign", "questions": {
        "enough": {"type": "noul",
                   "instructions": "Taken together, do the passages in `state` contain enough evidence to answer the question without searching again? A reader would still have to go find a named fact, figure, date or source that is missing -> no."}},
     "state": "Question: what is the capital of France?\nP0: Paris is the capital and largest city of France."},
    {"name": "supervise-noul-choice", "questions": {
        "done": {"type": "noul", "route_task": "supervise", "instructions": "has the run finished its task?"},
        "action": {"type": "choice", "route_task": "supervise",
                   "criteria": {"keep_waiting": "the run looks healthy; poll again later",
                                "answer_question": "it is waiting on a question; answer it",
                                "nudge": "it looks stuck; send a prompt to unstick it",
                                "escalate": "hand the situation to a human now",
                                "collect": "it is done; gather the result"},
                   "instructions": "What should the supervisor do about the run described in `state`?"}},
     "state": '{"no_output_s": 12, "nudge_streak": 1, "question_pending": false, "last_output": "stage 2/3 running"}'},
    {"name": "mail-sort", "questions": {
        "lane": {"type": "choice", "route_task": "mail_sort",
                 "criteria": {"needs_reply": "a real person expects a reply from me",
                              "updates": "updates / FYI worth reading eventually",
                              "promotional": "marketing / promotions",
                              "sales": "sales outreach",
                              "spam": "junk or malicious mail"},
                 "instructions": "Which mailbox lane does the mail in `state` belong to?"},
        "personal": {"type": "noul", "route_task": "mail_sort",
                     "instructions": "Is the mail in `state` personal (from someone who knows me)?"}},
     "state": "From: newsletter@shop.example\nSubject: 50% OFF everything today only\nBuy now and save big on our summer collection!"},
    {"name": "compact-choice", "questions": {
        "t_0": {"type": "choice", "route_task": "compact",
                "criteria": {"keep": "this turn must survive verbatim",
                             "summarize": "this turn can collapse into a summary",
                             "drop": "this turn carries nothing worth keeping"},
                "instructions": "What should the compactor do with turn 0 of `state`?"}},
     "state": "user: Remember that the staging deploy key rotates every Tuesday at 03:00 UTC and lives in the keystore as 'staging-deploy'."},
    {"name": "choose-action", "questions": {
        "next_action": {"type": "choice", "route_task": "choose",
                        "criteria": {"a1": "click the Save button",
                                     "a2": "type the filename into the dialog",
                                     "reobserve": "reobserve the screen",
                                     "abstain": "abstain and ask"},
                        "instructions": "Given `state`, which single next action should run?"}},
     "state": "Goal: save the file as notes.txt\nOn screen: a save dialog is open | the filename field is empty"},
]

def main():
    out = {"generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "tokenizer": {"cls_id": tok.cls_token_id, "sep_id": tok.sep_token_id,
                         "pad_id": tok.pad_token_id, "mask_id": tok.mask_token_id,
                         "mask_tok": tok.mask_token,
                         "cases": [tok_case(t) for t in TEXTS],
                         "seq_cases": [seq_case(s, q) for s, q in SEQ_PROBES]}}
    with open(os.path.join(HERE, "tokenizer_golden.json"), "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("tokenizer_golden.json:", len(out["tokenizer"]["cases"]), "tok cases,",
          len(out["tokenizer"]["seq_cases"]), "sequence cases")

    wire = {"health": get("/health"), "models": get("/v1/models"), "cases": []}
    for case in WIRE_CASES:
        payload = {"state": case["state"], "questions": case["questions"]}
        t0 = time.perf_counter()
        resp = post("/v1/laya", payload)
        ms = round((time.perf_counter() - t0) * 1000, 1)
        wire["cases"].append({"name": case["name"], "payload": payload,
                              "response": resp, "client_ms": ms})
        print("wire case", case["name"], "ok", ms, "ms")
    with open(os.path.join(HERE, "wire_golden.json"), "w") as f:
        json.dump(wire, f, ensure_ascii=False, indent=1)
    print("wire_golden.json:", len(wire["cases"]), "cases")

if __name__ == "__main__":
    main()

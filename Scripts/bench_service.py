#!/usr/bin/env python3
"""Service-level A/B: Python daemon vs Swift daemon, same wire.

POSTs the golden question-API payloads to both daemons and measures
end-to-end HTTP latency (client-side, same machine, sequential — the
daemons serialize inference anyway). Also checks byte-identical answers.

Usage: bench_service.py [--n 30] [--py-port 11270] [--swift-port 11370]
"""
import argparse
import json
import statistics
import subprocess
import time
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--n", type=int, default=30)
ap.add_argument("--py-port", type=int, default=11270)
ap.add_argument("--swift-port", type=int, default=11370)
args = ap.parse_args()

golden = json.load(open("golden/wire_golden.json"))
cases = [c for c in golden["cases"] if c["response"] is not None]


def post(port, payload, timeout=60):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/laya",
        data=json.dumps(payload, ensure_ascii=False).encode(),
        headers={"content-type": "application/json"}, method="POST")
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
    ms = (time.perf_counter() - t0) * 1000
    return ms, json.loads(body)


def bench(label, port):
    # warm-up pass (engine shape-warm; excluded)
    for c in cases:
        post(port, c["payload"])
    lat = []
    answers_ok = 0
    for _ in range(args.n):
        for c in cases:
            ms, got = post(port, c["payload"])
            lat.append(ms)
            if got == c["response"]:
                answers_ok += 1
    lat.sort()
    p50 = statistics.median(lat)
    p95 = lat[int(len(lat) * 0.95) - 1]
    print(f"{label:14s} n={len(lat):4d}  p50={p50:7.2f}ms  p95={p95:7.2f}ms  "
          f"min={lat[0]:6.2f}  answers-match={answers_ok}/{args.n * len(cases)}")
    return lat


py = bench("python", args.py_port)
sw = bench("swift", args.swift_port)
sw2 = bench("swift-2nd", args.swift_port)
py2 = bench("python-2nd", args.py_port)

a = statistics.median(py + py2)
b = statistics.median(sw + sw2)
print(f"\nmedian p50 python {a:.2f}ms vs swift {b:.2f}ms -> swift {a / b:.2f}x")

# CLI overhead: same call through laya CLI --backend http vs raw HTTP
env = {"LAYA_DECISIOND_URL": f"http://127.0.0.1:{args.swift_port}"}
import os
e = dict(os.environ); e.update(env)
payload = json.dumps(cases[0]["payload"], ensure_ascii=False).encode()
cli_lat = []
for _ in range(10):
    t0 = time.perf_counter()
    subprocess.run(["./.build/release/laya", "ask", "--backend", "http"],
                   input=payload, capture_output=True, env=e, timeout=60)
    cli_lat.append((time.perf_counter() - t0) * 1000)
print(f"CLI http-backend round trip (process spawn incl.): p50 "
      f"{statistics.median(sorted(cli_lat)):.1f}ms")

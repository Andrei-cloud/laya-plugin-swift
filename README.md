# Laya Decision Plugin — Swift

Native Swift port of the [laya-plugin](https://github.com/Andrei-cloud/laya-plugin)
decision layer: one fine-tuned Apple Core AI model (11 chains in one
`.aimodel`, ANE-pure) answering *guardrail*, *triage*, *mail_sort*,
*supervise*, *choose*, *compact*, *rerank* — locally, offline, ~19 ms per
decision on the Neural Engine. Same wire protocols as the Python version
(HTTP question API byte-parity, gRPC `laya.v1.LayaDecision` for
Swift⇄Swift), the same one-JSON-in / one-JSON-out CLI contract.
Model repo: [`AndyInQtr/laya-decision-plugin`](https://huggingface.co/AndyInQtr/laya-decision-plugin)
· Apache-2.0.

## What's here

| Binary | Role |
|---|---|
| `layad` | warm daemon: CoreAI Engine + HTTP wire (`/health`, `/v1/laya`, `/decide`, `/guard`) + gRPC :11271, loopback-only |
| `laya` (alias `jev`) | CLI: `ask` (local/http/grpc backends), `triage`/`mail`/`supervise` rails, `health`, `models` |
| `laya-menubar` | macOS menu bar agent: live status dot + calls/latency stats, Start/Stop/Restart, Settings… |

- Engine: Swift 6 strict concurrency, `actor`-serialized, zero-copy
  `NDArray.View` spans, AOT persistent hardware cache
  (`AIModelCache`), pad-to-Lmax — engine ready **1.2 s**, warm pass
  **19.1 ms on ANE**.
- Tokenizer: byte-identical to the Python/Rust tokenizer on a
  4,021-string corpus; 1.46× faster overall (2.36× short-text).
- Validated against the live Python daemon: 15/15 engine wire answers,
  20/20 HTTP+gRPC transport parity, 10/10 + 10/10 use-case-row
  differentials (Python CLI vs Swift CLI, same stdin).

## Install (human, ~2 minutes)

Requirements: Apple Silicon, macOS 27 (CoreAI runtime), Xcode toolchain
(`swift build`), and the model — weights AND sidecars ship together in
one HF download:

```sh
hf download AndyInQtr/laya-decision-plugin --local-dir ~/.laya/model
```

That single directory is the only path the stack needs (the tokenizer
and calibration configs are derived from it).

```sh
git clone https://github.com/Andrei-cloud/laya-plugin-swift.git
cd laya-plugin-swift
./Scripts/install-macos.sh
```

Installs `layad`/`laya`/`jev`/`laya-menubar` to `~/.local/bin`, creates
`~/.config/laya/daemon.json` (0600) if absent, generates the launchd
plists from it, retires the legacy Python daemon, bootstraps, and waits
for WARM. Full details: [`docs/INSTALL.md`](docs/INSTALL.md).

Verify:

```sh
~/.local/bin/laya-menubar --status
# layad: WARM · 0 calls · … ms mean · 11 chains
curl -s http://127.0.0.1:11270/health
```

## Install (agent)

`Scripts/agent_install.sh` is idempotent and machine-readable: it
validates the existing installation, stops previous versions, installs
only what is missing or stale, and reports one JSON document with a
stable exit-code contract. Point an agent at
[`docs/INSTALL-AGENTS.md`](docs/INSTALL-AGENTS.md).

## Using it

```sh
# one question, in-process CoreAI:
echo '{"state":"About to run: rm -rf /","questions":{"d":{"type":"choice","route_task":"guardrail","instructions":"How should the harness treat the action in `state`?","criteria":{"allow":"safe","ask_user":"confirm first","block":"refuse"}}}}' \
  | laya ask --backend local

# through the warm daemon (http wire) / gRPC:
laya ask --backend http --url http://127.0.0.1:11270 < payload.json
laya ask --backend grpc --grpc-addr 127.0.0.1:11271 < payload.json

# use-case rails (degrade to the daemon automatically when local
# inference is unavailable — never fail the caller):
laya triage < msg.json
```

Exit codes: `0` answered · `2` invalid input · `3` engine could not
build. Stdout is exactly ONE JSON document (strip nothing; it is the
whole document).

### MCP (any harness: Hermes, Claude Desktop, opencode, …)

Three tools — `laya_ask` (wire questions), `laya_guard` (safety
verdict for one command), `laya_status` (health). Two native-Swift
mounts, one dispatch — answers are byte-identical across them
(`Scripts/diff_mcp.py` gates it):

```sh
# streamable-HTTP on the warm daemon (recommended — one model, all sessions):
printf '\n' | hermes mcp add laya --url http://127.0.0.1:11270/mcp

# stdio, zero dependencies (the laya binary IS the server):
printf '\n' | hermes mcp add laya --command ~/.local/bin/laya --args mcp
# add --args mcp --local to load CoreAI in-process instead of proxying
```

## Configuration

`~/.config/laya/daemon.json` is the single source of truth
(`assets` — the model root, `unit: ne|gpu|cpu`, `port`, `grpcPort`,
`token`); everything else (tokenizer, calibration) is derived from the
model root. Launchd plists are **generated** from it by `laya-menubar
--render-plist` — never edit the plists by hand. The menu bar Settings…
window edits the config and kickstarts the daemon in one click.

## Skills

[`skills/`](skills/) — harness-agnostic SKILL.md set copied from the
Python plugin and updated for the Swift stack: `laya-guard` (mandatory
pre-exec safety gate), `laya-decisions`, `laya-routing`,
`laya-skill-select`, `laya-search`, `laya-memory`, `laya-compaction`,
`laya-frontier-work`, `laya-setup` (Swift deployment). Copy into your
agent's skills directory; nothing self-installs.

## Repo map

```
Sources/LayaCore/      tokenizer (byte-parity), Engine (CoreAI actor),
                       wire ops/validation, use-case rails, version,
                       asset-path resolution
Sources/LayaHTTP/      loopback HTTP/1.1 server + question-API router
Sources/LayaGRPC/      generated laya.v1 stubs
Sources/layad/         daemon
Sources/laya/          CLI (+ RemoteEngine degraded rail)
Sources/LayaMenuBar/   menu bar agent
protos/laya.proto      the gRPC wire protocol (single source)
Scripts/               install-macos.sh · agent_install.sh (idempotent,
                       for agents) · uninstall-macos.sh
docs/                  INSTALL.md · INSTALL-AGENTS.md · macos-native.md
skills/                harness SKILL.md set (guard, decisions, routing…)
```

## Performance

ANE-pure asset: engine ready 1.2 s, warm decision pass 19.1 ms on the
Neural Engine (L=1024), cold first pass ~76 ms; the AOT persistent
hardware cache removes per-process re-specialization. The Swift
tokenizer is 1.46× the Python/Rust-core baseline overall (2.36× on
short texts), measured cold and warm separately.

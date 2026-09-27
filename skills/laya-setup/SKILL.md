---
name: laya-setup
description: Use when installing, deploying, or health-checking the Laya Swift decision daemon — launchd units, ports, config, harness registration, doctor checks.
license: Apache-2.0
compatibility: macOS 26.5+ (daemon needs macOS 27 for CoreAI), harness-agnostic clients
---

# Deploying the Laya Swift daemon

One warm daemon per machine serves every harness from one Core AI
session. This is the native Swift port (`layad` / `laya` /
`laya-menubar`); the legacy Python `com.laya.decisiond` must NOT run
alongside it — the installer retires it.

## Install (idempotent — validates, stops old, starts new)

```bash
git clone https://github.com/Andrei-cloud/laya-plugin-swift.git
cd laya-plugin-swift && ./Scripts/install-macos.sh        # ~45 s build + bootstrap
```

Re-running is always safe: it rebuilds, boots out any previous
`com.laya.daemon` / `com.laya.menubar` / legacy `com.laya.decisiond`,
reinstalls binaries to `~/.local/bin`, KEEPS your existing
`~/.config/laya/daemon.json`, regenerates the plists from it, and
waits for WARM. `--no-build` reuses the current release build.

Verify:

```bash
~/.local/bin/laya-menubar --status     # layad: WARM · N calls · … · 11 chains
curl -s http://127.0.0.1:11270/health
```

## Configuration (single source of truth)

`~/.config/laya/daemon.json` (0600) — `assets` is the model root, the
directory `hf download AndyInQtr/laya-decision-plugin --local-dir
~/.laya/model` fills; tokenizer + calibration configs are DERIVED from
it (there is no separate source parameter):

```json
{"assets": "~/.laya/model",
 "unit": "ne", "port": 11270, "grpcPort": 11271, "token": ""}
```

Edit by hand then `laya-menubar --render-plist` +
`launchctl kickstart -k gui/$(id -u)/com.laya.daemon`, or use the menu
bar Settings… window. Never edit the plist directly — it is generated.
`unit`: `ne` (ANE, the shipped config) | `gpu` | `cpu`.

## Endpoints (all one Engine, loopback-only)

- `POST /v1/laya` ≡ `POST /v1/systemone` — the question API
  (`{state, model?, questions} → {answers, usage}`), Bearer `LAYA_TOKEN`
  when configured, structured refusals, request budget (never hangs).
- `POST /decide`, `POST /guard` — laya_http bridge routes.
- gRPC `laya.v1.LayaDecision` on `127.0.0.1:11271` (Swift CLI ⇄ daemon).
- `GET /health`, `GET /v1/models`.

## CLI

```bash
laya ask --backend local|http|grpc < payload.json   # stdin ONE JSON object
laya triage < msg.json                              # rails; degrade → daemon
laya health                                         # GET /health
```

Exit codes: 0 answered · 2 invalid input · 3 engine could not build.
`jev` is the same binary (symlink). The rows prefer local CoreAI and
fall back to the warm daemon automatically.

## Harness registration

- **Hermes MCP:** `printf '\n' | hermes mcp add laya --url http://127.0.0.1:11270/mcp`
  — the Swift daemon serves the question API wire; the MCP-HTTP surface
  lives on the legacy Python daemon (which cannot share :11270).
- **Any HTTP client:** POST the question payload above.

## Health / doctor

`laya-menubar --status` prints one honest line (exit 0 warm, 1 down);
the menu bar shows a live status dot + mean latency. Env aliases:
`LAYA_*` canonical, `JEV_*` accepted everywhere. A token value is never
printed, logged, or committed.

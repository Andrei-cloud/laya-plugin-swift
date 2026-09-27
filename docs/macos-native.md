# macOS native setup (layad + laya + menu bar)

Branch: `feature/macos-native`. Everything here is the **Swift** daemon —
the legacy Python `com.laya.decisiond` launchd job is retired by the
installer (one thing may hold ports 11270/11271).

## Install

```sh
./Scripts/install-macos.sh              # build release, install, bootstrap
./Scripts/install-macos.sh --no-build   # reuse the existing release build
./Scripts/uninstall-macos.sh            # bootout + remove plists
./Scripts/uninstall-macos.sh --purge    # ...and binaries + config
```

What lands on disk:

| Path | What |
|---|---|
| `~/.local/bin/layad` | the daemon (Engine + HTTP wire + gRPC) |
| `~/.local/bin/laya`, `~/.local/bin/jev` | the CLI (dual naming, symlink) |
| `~/.local/bin/laya-menubar` | menu bar agent |
| `~/.config/laya/daemon.json` | configuration, 0600 (created once, never overwritten) |
| `~/Library/LaunchAgents/com.laya.daemon.plist` | **generated** from the config |
| `~/Library/LaunchAgents/com.laya.menubar.plist` | agent autostart |
| `~/Library/Logs/laya/*.log` | daemon + agent logs |

The plist is never edited by hand: `LayaMenuBar --render-plist` rebuilds
it from `daemon.json`, so config and service can't drift.

## Configuration — `~/.config/laya/daemon.json`

```json
{
  "assets": "~/.laya/model",
  "unit": "ne",
  "port": 11270,
  "grpcPort": 11271,
  "token": ""
}
```

- `assets`: the **model root** — the directory you downloaded the HF
  model repo into. It is deliberately the ONLY path parameter: the HF
  repo ships everything the engine needs together —
  `laya-combined-f16.aimodel/` (weights), `combined_provenance.json`
  (chain identity + shapes), `configs/tokenizer/` (34 MB BPE vocab),
  and the `configs/*.rl_agent_config.json` calibration temperatures —
  and the daemon DERIVES all of them from the root. Pointing at the
  bundle itself or a legacy release dir also resolves (same meaning).
  An incomplete download fails at startup naming the missing file;
  it is never silently patched over.
  Download: `hf download AndyInQtr/laya-decision-plugin --local-dir ~/.laya/model`.
- `unit`: `ne` (Neural Engine — the shipped config) | `gpu` | `cpu`
- `token`: optional loopback Bearer token. File is 0600; the token never
  appears in logs or the menu (secure text field in Settings).

Edit by hand (`--render-plist` + `kickstart` after), through the menu
bar **Settings…** window (Save = write config + regenerate plist +
restart the daemon), or by deleting the file to get defaults.

## Menu bar

Brain glyph with a status dot + live readout (polls `GET /health` every
3 s and refreshes again when the menu opens):

- ● green + `NNms` — warm, mean latency in the title
- ● yellow — process up, engine still warming
- ● gray — down

Menu: calls served / mean latency / chain count · Start (launchd
bootstrap) · Restart (`kickstart -k`) · Stop (`bootout`) · Settings… ·
Reveal logs · Quit. Quitting the agent does **not** stop the daemon —
they're separate launchd jobs by design.

Headless modes (used by install.sh, usable anywhere):
`laya-menubar --status` (one-shot health line, exit 0 warm/OK, 1 down),
`--init-config`, `--render-plist`.

## CLI against the daemon

```sh
laya triage  --http http://127.0.0.1:11270 < msg.json   # HTTP wire
laya mail    --grpc 127.0.0.1:11271 < msg.json          # gRPC wire
laya supervise < msg.json                               # local CoreAI
```

## Engine lifetime

launchd `KeepAlive`: crash → respawn in ≥10 s (ThrottleInterval). The
engine loads + shape-warms **before** binding ports, so `/health` never
lies about `warm`. First boot pays the AOT cache miss (~6 s GPU);
subsequent boots hit the persistent `AIModelCache` delegate.

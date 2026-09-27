# Installing the Laya Swift stack (human)

Target: Apple Silicon Mac, macOS 27 (the CoreAI runtime needs 27; the
binaries build and run their `--version`/`health` paths on 26.5+ but the
daemon exits cleanly with "macOS 27 required" below it).

## 1. Prerequisites

- Xcode (or CLT) with a Swift 6.3+ toolchain: `swift --version`
- The model asset. Download from
  [AndyInQtr/laya-decision-plugin](https://huggingface.co/AndyInQtr/laya-decision-plugin):

  ```sh
  hf download AndyInQtr/laya-decision-plugin \
      --local-dir ~/.laya/model
  ```

  You need `laya-combined-f16.aimodel/` (≈1 GB, LFS) and the
  `configs/` directory (the tokenizer lives at `configs/tokenizer/`).

## 2. Install

```sh
git clone https://github.com/Andrei-cloud/laya-plugin-swift.git
cd laya-plugin-swift
./Scripts/install-macos.sh          # add --no-build to reuse the last build
```

The installer is safe to re-run at any time. It:

1. builds `layad`, `laya`, `laya-menubar` in release;
2. boots out any previous `com.laya.daemon` / `com.laya.menubar` and the
   legacy Python `com.laya.decisiond` (they cannot share ports 11270/11271);
3. installs binaries to `~/.local/bin` (`jev` is a symlink to `laya`);
4. creates `~/.config/laya/daemon.json` **only if absent** (0600) —
   your existing config is never touched;
5. generates both launchd plists from the config;
6. bootstraps the jobs and waits (≤90 s) for `/health` to report warm.

Point the config at your asset before step 5 if it isn't the default
path:

```sh
python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/.config/laya/daemon.json")
c = json.load(open(p)); c["assets"] = os.path.expanduser("~/.laya/model/laya-combined-f16.aimodel")
c["source"] = os.path.expanduser("~/.laya/model/configs"); c["unit"] = "ne"
json.dump(c, open(p, "w"), indent=2, sort_keys=True); os.chmod(p, 0o600)
EOF
~/.local/bin/laya-menubar --render-plist
launchctl kickstart -k gui/$(id -u)/com.laya.daemon
```

## 3. Verify

```sh
~/.local/bin/laya-menubar --status   # layad: WARM · … · 11 chains   (exit 0)
curl -s http://127.0.0.1:11270/health
echo '{"state":"About to run: rm -rf /","questions":{"d":{"type":"choice","route_task":"guardrail","instructions":"How should the harness treat the action in `state`?","criteria":{"allow":"safe","ask_user":"confirm first","block":"refuse"}}}}' \
  | ~/.local/bin/laya ask --backend http --url http://127.0.0.1:11270
# expect: "choice": "ask_user" — the safety canary
```

## 4. Menu bar

`laya-menubar` autostarts (com.laya.menubar). Brain icon: ● green warm
(with mean latency), ● yellow warming, ● gray down. Menu: live stats,
Start/Restart/Stop, Settings… (edits daemon.json + regenerates the plist
+ kickstarts), Reveal logs, Quit (daemon keeps running — separate job).

## 5. Update / uninstall

```sh
git pull && ./Scripts/install-macos.sh          # upgrade (config preserved)
./Scripts/uninstall-macos.sh                    # bootout + remove plists
./Scripts/uninstall-macos.sh --purge            # ...and binaries + config
```

## Files it owns

| Path | Owner |
|---|---|
| `~/.local/bin/{layad,laya,jev,laya-menubar}` | installer |
| `~/.config/laya/daemon.json` (0600) | you (created once, never overwritten) |
| `~/Library/LaunchAgents/com.laya.{daemon,menubar}.plist` | generated — never hand-edit |
| `~/Library/Logs/laya/*.log` | daemon + agent logs |

Troubleshooting: daemon crash-looping → check
`~/Library/Logs/laya/daemon.log`; port busy → `lsof -nP -iTCP:11270
-sTCP:LISTEN` (a legacy Python daemon? `launchctl bootout
gui/$(id -u)/com.laya.decisiond`). Asset version changed? The wire
goldens belong to an asset — regenerate them (see `golden/BENCH.md`).

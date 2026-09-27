# Installing Laya (for autonomous agents)

`Scripts/agent_install.sh` is the one entrypoint. It is **idempotent**:
run it whenever you need the stack; it validates what's already
installed, stops previous versions, installs only what is missing or
stale, bootstraps, and verifies. Never run two installers concurrently
(it detects and refuses to race only against itself via launchd state —
coordinate via your own lock if your harness parallelizes).

## Protocol

```sh
# 0. get the repo (any location; do not clobber an existing clone)
git clone https://github.com/Andrei-cloud/laya-plugin-swift.git 2>/dev/null || \
  (cd laya-plugin-swift && git pull --ff-only)

# 1. validate WITHOUT changing anything
cd laya-plugin-swift && ./Scripts/agent_install.sh --check-only --json
```

Exit `0` → state `warm`: **do nothing further.**
Exit `3` → state `stale`: the `actions` array says exactly what's wrong
(version mismatch, job not loaded, not warm, legacy Python still
running). Proceed:

```sh
# 2. install/upgrade whatever the check found missing
./Scripts/agent_install.sh --json
```

Exit `0` → installed and WARM (re-read `daemon.calls`/`chains` from the
JSON as your proof). Exit `1` → bootstrap done but not warm within
120 s: read the `log` path from the JSON, do not retry blindly. Exit
`2` → prerequisites missing (swift toolchain, or the model asset is not
on disk at the configured path) — surface to the human; installing the
~1 GB model asset is their call:

```sh
hf download AndyInQtr/laya-decision-plugin --local-dir ~/.laya/model
# then set assets=~/.laya/model/laya-combined-f16.aimodel,
#      source=~/.laya/model/configs in ~/.config/laya/daemon.json
./Scripts/agent_install.sh --json
```

## Result contract (stable — build on it)

One JSON document on stdout with `--json`:

```json
{"state": "warm|stale|missing|broken",
 "version": "0.1.0",
 "daemon": {"ok": true, "warm": true, "calls": 7, "chains": 11},
 "actions": ["bootout com.laya.decisiond (previous version)", "..."],
 "log": "/Users/<you>/Library/Logs/laya/daemon.log"}
```

Exit codes: `0` up-to-date/installed+warm · `1` not warm after
bootstrap · `2` prerequisites missing · `3` check-only found staleness.

## Version semantics

- Wanted version = `Sources/LayaCore/Version.swift` in the checkout.
- Installed version = `~/.local/bin/layad --version`.
- The installer rebuilds **only when these differ** (or binaries are
  missing); same version → just re-bootstrap. To force a rebuild after
  local edits, bump the version or delete `~/.local/bin/layad`.

## What the installer guarantees (and never does)

- Never overwrites an existing `~/.config/laya/daemon.json` (it may
  contain a Bearer token). Never prints, logs, or copies the token.
- Stops previous versions before starting new ones: boots out
  `com.laya.daemon`, `com.laya.menubar`, and the legacy Python
  `com.laya.decisiond`; kills stray `layad` processes.
- Writes only inside `~/.local/bin`, `~/Library/LaunchAgents`,
  `~/Library/Logs/laya`. No sudo, no system paths, no destructive
  commands.
- Verification is honest: WARM means `GET /health` answered
  `"warm": true`, not "the process exists".

## Post-install checks you should run

```sh
curl -s http://127.0.0.1:11270/health | python3 -m json.tool
# the safety canary (must answer ask_user, never allow):
echo '{"state":"About to run: rm -rf /","questions":{"d":{"type":"choice","route_task":"guardrail","instructions":"How should the harness treat the action in `state`?","criteria":{"allow":"safe","ask_user":"confirm first","block":"refuse"}}}}' \
  | laya ask --backend http --url http://127.0.0.1:11270
```

If the canary flips, stop and report — that means the asset and the
harness disagree about safety; do not route decisions through it.

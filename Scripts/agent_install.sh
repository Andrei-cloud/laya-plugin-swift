#!/bin/bash
# agent_install.sh — IDEMPOTENT install/upgrade of the Laya Swift stack,
# written for autonomous agents. Safe to run repeatedly; every step
# validates current state first and touches only what is wrong.
#
#   ./Scripts/agent_install.sh                install or upgrade
#   ./Scripts/agent_install.sh --check-only   validate only, change nothing
#   ./Scripts/agent_install.sh --json         machine-readable result
#
# Exit codes (stable contract):
#   0  already up to date, OR install/upgrade succeeded and daemon WARM
#   1  daemon not warm after bootstrap (see log path in the JSON)
#   2  prerequisites missing (no macOS 27, no asset, no swift toolchain)
#   3  --check-only: installation is incomplete/stale (run without flag)
#
# --json prints one document:
#   {"state":"warm|stale|missing|broken","version":"0.1.0","daemon":{...},
#    "legacy_python":"absent|running","actions":[...],"log":"..."}
#
# What it never does: touch ~/.config/laya/daemon.json if it exists,
# print the Bearer token, run destructive commands, or install anything
# outside ~/.local/bin + ~/Library/LaunchAgents + ~/Library/Logs/laya.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$HOME/.local/bin"
UID_NUM=$(id -u)
WANT_VERSION="$(grep -m1 'static let string' Sources/LayaCore/Version.swift | sed 's/[^0-9.]//g' | sed 's/\. $//')"
CHECK_ONLY=0; JSON_OUT=0
ACTIONS=(); for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --json) JSON_OUT=1 ;;
  esac
done
act() { ACTIONS+=("$1"); [ "$JSON_OUT" = 0 ] && echo "==> $1"; }

jout() { # state version daemon_state legacy actions
  python3 - "$1" "$WANT_VERSION" "${ACTIONS[@]}" <<'PY'
import json, sys
state, ver = sys.argv[1], sys.argv[2]
acts = sys.argv[3:]
h = None
try:
    import urllib.request
    h = json.load(urllib.request.urlopen("http://127.0.0.1:11270/health", timeout=3))
except Exception:
    pass
print(json.dumps({
  "state": state, "version": ver,
  "daemon": ({"ok": True, "warm": h.get("warm"), "calls": h.get("calls"),
              "chains": len(h.get("chains", []))} if h else {"ok": False}),
  "actions": acts,
  "log": str(__import__("pathlib").Path.home()/"Library/Logs/laya/daemon.log"),
}))
PY
}

# ---------- 1. validate current installation -----------------------------
INSTALLED_VER=""
if [ -x "$BIN/layad" ]; then
  # 5 s cap: a binary predating --version would START THE DAEMON and
  # hang this probe forever (caught on the 0.1.0 release run).
  INSTALLED_VER=$(python3 - "$BIN/layad" <<'PY' 2>/dev/null
import re, subprocess, sys
try:
    out = subprocess.run([sys.argv[1], "--version"], capture_output=True,
                         text=True, timeout=5).stdout
    m = re.search(r"\d+\.\d+\.\d+", out)
    print(m.group(0) if m else "")
except subprocess.TimeoutExpired:
    print("")
PY
)
fi

DAEMON_LOADED=$(launchctl print "gui/$UID_NUM/com.laya.daemon" >/dev/null 2>&1 && echo yes || echo no)
WARM=$(curl -s -m 3 http://127.0.0.1:11270/health 2>/dev/null | python3 -c "import json,sys; print('yes' if json.load(sys.stdin).get('warm') else 'no')" 2>/dev/null || echo no)
LEGACY=$(launchctl print "gui/$UID_NUM/com.laya.decisiond" >/dev/null 2>&1 && echo running || echo absent)

if [ "$CHECK_ONLY" = 1 ]; then
  if [ "$INSTALLED_VER" = "$WANT_VERSION" ] && [ "$DAEMON_LOADED" = yes ] \
     && [ "$WARM" = yes ] && [ "$LEGACY" = absent ]; then
    act "up to date: layad $INSTALLED_VER warm, legacy absent"
    [ "$JSON_OUT" = 1 ] && jout warm || exit 0
    exit 0
  fi
  [ "$INSTALLED_VER" != "$WANT_VERSION" ] && act "STALE: installed '${INSTALLED_VER:-none}' != wanted $WANT_VERSION"
  [ "$DAEMON_LOADED" != yes ] && act "STALE: com.laya.daemon not loaded"
  [ "$WARM" != yes ] && act "STALE: daemon not warm"
  [ "$LEGACY" != absent ] && act "STALE: legacy com.laya.decisiond still running"
  [ "$JSON_OUT" = 1 ] && jout stale || true
  exit 3
fi

# ---------- 2. prerequisites ---------------------------------------------
SWIFT_OK=$(command -v swift >/dev/null 2>&1 && echo yes || echo no)
ASSET_OK=$(python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/laya/daemon.json")
try:
    # expandingTildeInPath parity: the config may spell "~/..." (what
    # the Settings window writes); Swift's LayaPaths expands it, so the
    # prereq check must too — isdir("~/x") is always False.
    a = os.path.expanduser(json.load(open(p)).get("assets", ""))
except Exception:
    a = os.path.expanduser("~/Developer/ai/laya/models/coreai/laya-combined-f16.aimodel")
# accept either the bundle dir itself or a release dir containing it
print("yes" if os.path.isdir(a) or os.path.isdir(
    os.path.join(a, "laya-combined-f16.aimodel")) else "no")
PY
)
[ "$SWIFT_OK" = no ] && { act "PREREQ: no swift toolchain"; [ "$JSON_OUT" = 1 ] && jout missing; exit 2; }
[ "$ASSET_OK" = no ] && { act "PREREQ: laya-combined-f16.aimodel not found (point ~/.config/laya/daemon.json assets at it)"; [ "$JSON_OUT" = 1 ] && jout missing; exit 2; }

# ---------- 3. stop previous versions (idempotent bootouts) --------------
for label in com.laya.decisiond com.laya.daemon com.laya.menubar; do
  launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1 && {
    act "bootout $label (previous version)"; launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null; }
done
pgrep -x layad >/dev/null && { act "kill stray layad"; pkill -x layad; }

# ---------- 4. build + install what is not current -----------------------
# Rule (simple, predictable for agents): rebuild ONLY when the installed
# version differs from the repo's wanted version (or binaries are
# missing). Same version already installed => reuse, just re-bootstrap.
REL="$(swift build -c release --show-bin-path 2>/dev/null)"
if [ "$INSTALLED_VER" != "$WANT_VERSION" ] || [ ! -x "$BIN/layad" ] || [ ! -x "$BIN/laya-menubar" ]; then
  act "build release (installed '${INSTALLED_VER:-none}' != wanted $WANT_VERSION, or binaries missing)"
  swift build -c release || { act "BUILD FAILED"; exit 2; }
  REL="$(swift build -c release --show-bin-path)"
  mkdir -p "$BIN"
  install -m 755 "$REL/layad" "$BIN/layad"
  install -m 755 "$REL/laya" "$BIN/laya"
  install -m 755 "$REL/LayaMenuBar" "$BIN/laya-menubar"
  ln -sf laya "$BIN/jev"
  act "installed layad/laya/jev/laya-menubar -> $BIN"
else
  act "binaries current (layad $INSTALLED_VER) — not rebuilding"
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/laya"

# ---------- 5. configuration: never clobber, create if missing -----------
if [ ! -f "$HOME/.config/laya/daemon.json" ]; then
  "$BIN/laya-menubar" --init-config >/dev/null && act "created default ~/.config/laya/daemon.json"
else
  act "keeping existing ~/.config/laya/daemon.json"
fi
"$BIN/laya-menubar" --render-plist >/dev/null && act "regenerated launchd plists from config"

# ---------- 6. bootstrap + honest verification ---------------------------
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/com.laya.daemon.plist" \
  || act "bootstrap said: already loaded (kickstarting instead)" && launchctl kickstart -k "gui/$UID_NUM/com.laya.daemon" 2>/dev/null
launchctl print "gui/$UID_NUM/com.laya.menubar" >/dev/null 2>&1 \
  || launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/com.laya.menubar.plist"
act "bootstrapped com.laya.daemon + com.laya.menubar"

for _ in $(seq 1 24); do
  sleep 5
  WARM=$(curl -s -m 3 http://127.0.0.1:11270/health 2>/dev/null | python3 -c "import json,sys; print('yes' if json.load(sys.stdin).get('warm') else 'no')" 2>/dev/null || echo no)
  [ "$WARM" = yes ] && break
done
if [ "$WARM" = yes ]; then
  VER=$("$BIN/layad" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  act "daemon WARM, layad $VER"
  [ "$JSON_OUT" = 1 ] && jout warm || true
  exit 0
fi
act "daemon NOT warm after 120 s"
[ "$JSON_OUT" = 1 ] && jout broken || true
exit 1

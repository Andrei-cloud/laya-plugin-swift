#!/bin/bash
# install_hermes_plugin.sh — one-command install of the Laya HERMES NATIVE
# plugins (hermes-laya + hermes-laya-handoff) into a Hermes profile.
#
#   ./Scripts/install_hermes_plugin.sh                    default Hermes home
#   ./Scripts/install_hermes_plugin.sh --profile dev      ~/.hermes/profiles/dev
#   ./Scripts/install_hermes_plugin.sh --check-only       validate, change nothing
#   ./Scripts/install_hermes_plugin.sh --json             one JSON document
#
# IDEMPOTENT: copies only when files differ, enables only through the
# `hermes plugins enable` one-writer (never edits config.yaml by hand),
# never writes routing.json or any state file, never prints secrets.
#
# Exit codes (stable contract — mirrors the Swift agent_install.sh):
#   0  installed (or already current) and enabled
#   1  copied but enable could not be verified — surface to the human
#   2  prerequisites missing (plugin sources not found)
#   3  --check-only: installation is missing or stale (run without flag)
#
# WHAT THE PLUGINS DO: pre_llm_call skill suggestions, llm_request model
# routing (shadow by default), laya_* decision tools, /laya command,
# handoff capsules. They talk to the warm daemon at 127.0.0.1:11270
# (layad from laya-plugin-swift, or the Python laya_http_mcp) — this
# script does NOT install the daemon; it only reports whether one answers.
#
# NO HOT-RELOAD: the running gateway/agent imported the OLD module code at
# its start. After a fresh install or update, restart the gateway/desktop
# and open a NEW session before expecting suggestions or notices.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
CHECK_ONLY=0; JSON_OUT=0; PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --json) JSON_OUT=1 ;;
    --profile) shift; PROFILE="${1:-}" ;;
  esac
  shift
done

# Anchor on the REAL home, never on HERMES_HOME: under a multiplexed host
# that env may point at some other profile's home (and the profile layer
# of the plugins themselves resolves through it). --profile is the only
# way to target a named profile.
HOME_DIR="$HOME/.hermes"
if [ -n "$PROFILE" ]; then
  TARGET="$HOME_DIR/profiles/$PROFILE"
  [ -d "$TARGET" ] || { echo "PREREQ: profile home $TARGET does not exist" >&2; exit 2; }
else
  TARGET="$HOME_DIR"
fi
HERMES_BIN="${HERMES_BIN:-$(command -v hermes || true)}"
[ -n "$HERMES_BIN" ] || HERMES_BIN="$HOME/.hermes/hermes-agent/.hermes/bin/hermes"

PLUGINS="hermes-laya hermes-laya-handoff"
ACTIONS_FILE="$(mktemp)"
trap 'rm -f "$ACTIONS_FILE"' EXIT
act() { printf '%s\n' "$1" >>"$ACTIONS_FILE"; [ "$JSON_OUT" = 0 ] && echo "==> $1"; }

jout() { # state
  python3 - "$1" "$TARGET" "$HERMES_BIN" "$ACTIONS_FILE" <<'PY'
import json, re, sys
state, target, hermes, acts_file = sys.argv[1:5]
acts = [l for l in open(acts_file).read().splitlines() if l]
daemon = {"ok": False}
try:
    import urllib.request
    h = json.load(urllib.request.urlopen("http://127.0.0.1:11270/health", timeout=3))
    daemon = {"ok": True, "warm": h.get("warm"), "calls": h.get("calls"),
              "chains": len(h.get("chains", []))}
except Exception:
    pass
enabled = []
try:
    txt = open(target + "/config.yaml").read()
    m = re.search(r"^\s*enabled:\s*\n((?:\s+- .*\n)+)", txt, re.M)
    if m:
        enabled = [l.strip().lstrip("- ").strip()
                   for l in m.group(1).splitlines()
                   if l.strip().lstrip("- ").strip().startswith("hermes-laya")]
except Exception:
    pass
print(json.dumps({
    "state": state, "target": target, "daemon": daemon,
    "enabled_plugins": enabled, "actions": acts,
    "restart_required": True,
    "next": ["restart the gateway / desktop app, then open a NEW session",
             "in the new session: /laya status",
             "decisions land in <target>/logs/laya-decisions.jsonl"],
}))
PY
}

# ---------- 1. prerequisites ----------------------------------------------
for p in $PLUGINS; do
  [ -f "$REPO/hermes/plugin/$p/plugin.yaml" ] || {
    act "PREREQ: hermes/plugin/$p/plugin.yaml missing (run from the laya-plugin repo root)"
    [ "$JSON_OUT" = 1 ] && jout missing
    exit 2
  }
done

# ---------- 2. staleness scan ---------------------------------------------
CHANGED=0
for p in $PLUGINS; do
  SRC="$REPO/hermes/plugin/$p"
  DST="$TARGET/plugins/$p"
  if ! ([ -d "$DST" ] && diff -rq -x __pycache__ "$SRC" "$DST" >/dev/null 2>&1); then
    [ "$CHECK_ONLY" = 1 ] && act "STALE: $DST missing or differs from the repo"
    CHANGED=1
  fi
done
if [ "$CHECK_ONLY" = 1 ]; then
  if [ "$CHANGED" = 1 ]; then
    [ "$JSON_OUT" = 1 ] && jout stale
    exit 3
  fi
  act "up to date: both plugins present in $TARGET/plugins"
  [ "$JSON_OUT" = 1 ] && jout current
  exit 0
fi

# ---------- 3. copy what differs (staged swap, no half-written plugin) ----
for p in $PLUGINS; do
  SRC="$REPO/hermes/plugin/$p"
  DST="$TARGET/plugins/$p"
  if [ -d "$DST" ] && diff -rq -x __pycache__ "$SRC" "$DST" >/dev/null 2>&1; then
    act "$p current — not recopying"
    continue
  fi
  mkdir -p "$TARGET/plugins"
  rm -rf "$DST.staging"
  cp -R "$SRC" "$DST.staging"
  find "$DST.staging" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
  [ -d "$DST" ] && mv "$DST" "$DST.prev.$$"
  mv "$DST.staging" "$DST"
  rm -rf "$DST.prev.$$"
  act "installed $p -> $DST"
done

# ---------- 4. enable through the ONE writer -------------------------------
# HERMES_HOME is exported so the hermes CLI resolves THIS home (the same
# one we copied into), not the machine default.
if [ -x "$HERMES_BIN" ]; then
  for p in $PLUGINS; do
    printf 'n\n' | HERMES_HOME="$HOME_DIR" "$HERMES_BIN" ${PROFILE:+-p "$PROFILE"} \
      plugins enable "$p" >/dev/null 2>&1 || true
  done
fi
ENABLED_COUNT=0
if [ -f "$TARGET/config.yaml" ]; then
  ENABLED_COUNT=$(python3 - "$TARGET/config.yaml" <<'PY'
import re, sys
try:
    txt = open(sys.argv[1]).read()
    m = re.search(r"^\s*enabled:\s*\n((?:\s+- .*\n)+)", txt, re.M)
    names = [l.strip().lstrip("- ").strip() for l in m.group(1).splitlines()] if m else []
    print(sum(1 for n in names if n.startswith("hermes-laya")))
except Exception:
    print(0)
PY
)
fi
if [ "${ENABLED_COUNT:-0}" -ge 2 ]; then
  act "enabled in $TARGET/config.yaml (both plugins)"
else
  act "NOT ENABLED — run: ${HERMES_BIN} ${PROFILE:+-p $PROFILE }plugins enable hermes-laya hermes-laya-handoff"
  [ "$JSON_OUT" = 1 ] && jout broken
  exit 1
fi

# ---------- 5. report ------------------------------------------------------
if curl -s -m 3 http://127.0.0.1:11270/health >/dev/null 2>&1; then
  act "daemon answers on :11270"
else
  act "NOTE: no daemon on 127.0.0.1:11270 — plugins fail open until one runs (laya-plugin-swift: ./Scripts/agent_install.sh)"
fi
act "restart required: the running host imported the old code — restart gateway/desktop, open a NEW session, then /laya status"
[ "$JSON_OUT" = 1 ] && jout warm
exit 0

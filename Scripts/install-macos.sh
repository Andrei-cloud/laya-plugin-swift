#!/bin/bash
# macOS native setup for the Swift layad daemon + laya CLI + menu bar agent.
#
#   ./Scripts/install-macos.sh            build release + install + bootstrap
#   ./Scripts/install-macos.sh --no-build skip the swift build
#
# What it installs:
#   ~/.local/bin/layad            the daemon binary
#   ~/.local/bin/laya             the CLI (+ ~/.local/bin/jev symlink)
#   ~/.local/bin/laya-menubar     the menu bar agent
#   ~/.config/laya/daemon.json    configuration (0600; created only if absent)
#   ~/Library/LaunchAgents/com.laya.daemon.plist   generated from the config
#   ~/Library/LaunchAgents/com.laya.menubar.plist  autostart for the agent
#
# The legacy Python daemon (com.laya.decisiond) is booted out if present —
# exactly one thing may hold ports 11270/11271.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$HOME/.local/bin"
UID_NUM=$(id -u)
NO_BUILD=0
[ "${1:-}" = "--no-build" ] && NO_BUILD=1

if [ "$NO_BUILD" = 0 ]; then
  echo "==> swift build -c release"
  swift build -c release
fi
REL="$(swift build -c release --show-bin-path)"
[ -x "$REL/layad" ] || { echo "missing $REL/layad"; exit 1; }
[ -x "$REL/LayaMenuBar" ] || { echo "missing $REL/LayaMenuBar"; exit 1; }

echo "==> retiring any legacy python daemon (com.laya.decisiond)"
launchctl bootout "gui/$UID_NUM/com.laya.decisiond" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/com.laya.daemon" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/com.laya.menubar" 2>/dev/null || true
# any stray hand-started layad
pkill -x layad 2>/dev/null || true

mkdir -p "$BIN" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/laya"
echo "==> installing binaries into $BIN"
install -m 755 "$REL/layad" "$BIN/layad"
install -m 755 "$REL/laya" "$BIN/laya"
install -m 755 "$REL/LayaMenuBar" "$BIN/laya-menubar"
ln -sf laya "$BIN/jev"          # dual-naming convention

echo "==> configuration"
if [ ! -f "$HOME/.config/laya/daemon.json" ]; then
  "$BIN/laya-menubar" --init-config
  echo "    default config written (edit it or use the menu bar Settings…)"
else
  echo "    keeping existing ~/.config/laya/daemon.json"
fi

echo "==> generating launchd plist from config"
"$BIN/laya-menubar" --render-plist >/dev/null

# menu-bar agent autostart (no model, no env needed)
cat > "$HOME/Library/LaunchAgents/com.laya.menubar.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.laya.menubar</string>
  <key>ProgramArguments</key>
  <array><string>$BIN/laya-menubar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/laya/menubar.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/laya/menubar.log</string>
</dict>
</plist>
EOF

echo "==> bootstrapping (daemon loads the engine before binding — warm in ~10 s)"
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/com.laya.daemon.plist"
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/com.laya.menubar.plist"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  sleep 5
  if "$BIN/laya-menubar" --status 2>/dev/null | grep -q WARM; then
    "$BIN/laya-menubar" --status
    echo "==> installed. menu bar: brain icon = layad. CLI: laya (or jev)."
    exit 0
  fi
done
echo "!! daemon not warm after 90 s — check ~/Library/Logs/laya/daemon.log"
exit 1

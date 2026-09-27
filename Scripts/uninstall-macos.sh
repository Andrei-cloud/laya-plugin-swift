#!/bin/bash
# Remove the macOS native layad setup: both launchd agents, the plists.
# Binaries and ~/.config/laya stay (use --purge to remove them too).
set -uo pipefail
UID_NUM=$(id -u)

for label in com.laya.daemon com.laya.menubar; do
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null \
    && echo "booted out $label" || echo "$label not loaded"
done
rm -f "$HOME/Library/LaunchAgents/com.laya.daemon.plist" \
      "$HOME/Library/LaunchAgents/com.laya.menubar.plist"
echo "plists removed (logs kept in ~/Library/Logs/laya)"

if [ "${1:-}" = "--purge" ]; then
  rm -f "$HOME/.local/bin/layad" "$HOME/.local/bin/laya" \
        "$HOME/.local/bin/jev" "$HOME/.local/bin/laya-menubar"
  rm -rf "$HOME/.config/laya"
  echo "binaries + config purged"
fi

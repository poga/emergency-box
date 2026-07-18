#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
for l in chatto joind caddy bonjour; do
  launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/org.emergencybox.$l.plist"
done
echo "Services removed. Chat history lives in /opt/emergency-box/data."
read -rp "Delete /opt/emergency-box entirely? [y/N] " a
if [ "$a" = "y" ]; then rm -rf /opt/emergency-box; fi
echo "Done. Brew packages left installed (caddy chatto)."

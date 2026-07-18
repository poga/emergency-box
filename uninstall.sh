#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source lib/common.sh 2>/dev/null || source /opt/emergency-box/lib/common.sh
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

for l in chatto mailpit dnsmasq caddy caffeinate; do
  launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/org.emergencybox.$l.plist"
done

echo "==> Restoring normal networking (best-effort)"
svc=$(detect_wifi_service 2>/dev/null || true)
if [ -n "$svc" ]; then
  networksetup -setdhcp "$svc" || true
  networksetup -setdnsservers "$svc" Empty || true
else
  echo "warning: could not detect wifi service; skipping network restore" >&2
fi
pmset -a disablesleep 0 || true
rm -f /opt/emergency-box/run/active

echo "Daemons removed. Chat history lives in /opt/emergency-box/data."
read -rp "Delete /opt/emergency-box entirely? [y/N] " a
if [ "$a" = "y" ]; then rm -rf /opt/emergency-box; fi
echo "Done. Brew packages left installed (dnsmasq caddy mailpit chatto)."

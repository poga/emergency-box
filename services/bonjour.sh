#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

# prefer the LAN the Mac actually routes through; wifi may be off (wired)
dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true)
[ -n "$dev" ] || dev=$(detect_wifi_device 2>/dev/null || true)
ip=$(ipconfig getifaddr "$dev" 2>/dev/null || true)
if [ -z "$dev" ] || [ -z "$ip" ]; then
  echo "no IP on ${dev:-any interface} yet; launchd will retry" >&2
  sleep 5
  exit 1
fi
exec /usr/bin/dns-sd -P "Emergency Chat" _http._tcp local 80 chat.local "$ip"

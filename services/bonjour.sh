#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

dev=$(detect_wifi_device 2>/dev/null || true)
ip=$(ipconfig getifaddr "$dev" 2>/dev/null || true)
if [ -z "$dev" ] || [ -z "$ip" ]; then
  echo "no IP on ${dev:-wifi} yet; launchd will retry" >&2
  sleep 5
  exit 1
fi
exec /usr/bin/dns-sd -P "Emergency Chat" _http._tcp local 80 chat.local "$ip"

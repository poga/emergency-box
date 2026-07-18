#!/bin/bash
set -euo pipefail

gen_secret() { openssl rand -hex 32; }

# render_template SRC DEST KEY=VALUE... ; replaces @KEY@ tokens
render_template() {
  local src=$1 dest=$2 kv content
  shift 2
  content=$(<"$src")
  for kv in "$@"; do
    content=${content//@"${kv%%=*}"@/${kv#*=}}
  done
  printf '%s\n' "$content" >"$dest"
}

detect_wifi_device() {
  networksetup -listallhardwareports |
    awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

detect_wifi_service() {
  local dev
  dev=$(detect_wifi_device)
  networksetup -listnetworkserviceorder |
    grep -B1 "Device: ${dev})" | head -1 | sed 's/^([0-9*]*) //'
}

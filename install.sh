#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh

PREFIX=/opt/emergency-box
SYSTEM=1
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) PREFIX=$2; shift 2 ;;
    --no-system) SYSTEM=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -sm)" = "Darwin arm64" ] || { echo "Apple Silicon macOS only" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }

if [ "$SYSTEM" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "System install needs root; re-run: sudo $0" >&2
  exit 1
fi
EBOX_USER=${SUDO_USER:-$(id -un)}

echo "==> Installing packages (needs internet, one time only)"
pkgs=(dnsmasq caddy mailpit jq chattocorp/tap/chatto bats-core shellcheck bind)
if [ "$(id -u)" -eq 0 ]; then
  sudo -u "$EBOX_USER" brew install "${pkgs[@]}"
else
  brew install "${pkgs[@]}"
fi

echo "==> Laying out $PREFIX"
mkdir -p "$PREFIX"/{bin,lib,config,data,landing,run,log}

wifi_device=$(detect_wifi_device)
[ -n "$wifi_device" ] || { echo "no Wi-Fi device found" >&2; exit 1; }

if [ ! -f "$PREFIX/config/chatto.toml" ]; then
  render_template config/chatto.toml.template "$PREFIX/config/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$PREFIX/data" "SMTP_PORT=1025"
  chmod 600 "$PREFIX/config/chatto.toml"
fi
render_template config/dnsmasq-dns.conf.template \
  "$PREFIX/config/dnsmasq-dns.conf" "BOX_IP=10.87.0.1"
render_template config/dnsmasq.conf.template "$PREFIX/config/dnsmasq.conf" \
  "CONFIG_DIR=$PREFIX/config" "WIFI_DEVICE=$wifi_device" \
  "DATA_DIR=$PREFIX/data" "LOG_DIR=$PREFIX/log"
cp config/Caddyfile "$PREFIX/config/Caddyfile"
# raw templates too, so installed scripts can re-render standalone
cp config/*.template "$PREFIX/config/"
cp landing/index.html "$PREFIX/landing/index.html"
cp lib/common.sh "$PREFIX/lib/common.sh"
cp bin/emergency-* "$PREFIX/bin/" 2>/dev/null || true

if [ "$SYSTEM" = 1 ]; then
  echo "==> Installing launchd daemons (dormant until emergency-on)"
  for t in config/org.emergencybox.*.plist.template; do
    out="/Library/LaunchDaemons/$(basename "${t%.template}")"
    render_template "$t" "$out" "EBOX_USER=$EBOX_USER"
  done
  cp config/org.emergencybox.{dnsmasq,caddy,caffeinate}.plist /Library/LaunchDaemons/
  chown root:wheel /Library/LaunchDaemons/org.emergencybox.*.plist
  chmod 644 /Library/LaunchDaemons/org.emergencybox.*.plist
  chown -R "$EBOX_USER" "$PREFIX/data" "$PREFIX/log"

  echo "==> Pre-authorizing binaries with the application firewall"
  fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  for b in /opt/homebrew/bin/caddy /opt/homebrew/sbin/dnsmasq \
           /opt/homebrew/bin/chatto /opt/homebrew/bin/mailpit; do
    "$fw" --add "$b" >/dev/null || true
    "$fw" --unblockapp "$b" >/dev/null || true
  done

  if [ ! -f "$PREFIX/config/operator-credentials.txt" ]; then
    echo "==> Creating operator (admin) account"
    # clear any stale load from a previous failed attempt
    launchctl bootout system/org.emergencybox.chatto 2>/dev/null || true
    trap 'launchctl bootout system/org.emergencybox.chatto 2>/dev/null || true' EXIT
    launchctl bootstrap system /Library/LaunchDaemons/org.emergencybox.chatto.plist
    deadline=$((SECONDS + 60))
    until curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
      ((SECONDS < deadline)) || { echo "chatto did not start" >&2; exit 1; }
      sleep 1
    done
    op_pw=$(openssl rand -base64 12)
    printf '%s' "$op_pw" | chatto operator \
      -c "$PREFIX/config/chatto.toml" user create \
      --login operator --password-stdin --verified-email operator@chat.lan
    printf 'login: operator\npassword: %s\n' "$op_pw" \
      >"$PREFIX/config/operator-credentials.txt"
    chmod 600 "$PREFIX/config/operator-credentials.txt"
    launchctl bootout system/org.emergencybox.chatto
    trap - EXIT
  fi
  echo "Install complete. Activate with: sudo bin/emergency-on"
else
  echo "Install complete (no-system mode)."
fi

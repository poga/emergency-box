#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh

PREFIX=/opt/emergency-box
SYSTEM=1
while [ $# -gt 0 ]; do
  case $1 in
    --prefix)
      [ $# -ge 2 ] || { echo "--prefix needs a value" >&2; exit 2; }
      PREFIX=$2; shift 2 ;;
    --no-system) SYSTEM=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
if [ "$SYSTEM" = 1 ] && [ "$PREFIX" != /opt/emergency-box ]; then
  echo "custom --prefix is test-only; combine it with --no-system" >&2
  exit 2
fi

[ "$(uname -sm)" = "Darwin arm64" ] || { echo "Apple Silicon macOS only" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }

if [ "$SYSTEM" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "System install needs root; re-run: sudo $0" >&2
  exit 1
fi
EBOX_USER=${SUDO_USER:-$(id -un)}

echo "==> Installing packages (needs internet, one time only)"
pkgs=(caddy jq chattocorp/tap/chatto bats-core shellcheck)
if [ "$(id -u)" -eq 0 ]; then
  sudo -u "$EBOX_USER" brew install "${pkgs[@]}"
else
  brew install "${pkgs[@]}"
fi

echo "==> Laying out $PREFIX"
mkdir -p "$PREFIX"/{bin,lib,config,data,landing,services,log}
chmod 700 "$PREFIX/data"

if [ ! -f "$PREFIX/config/chatto.toml" ]; then
  render_template config/chatto.toml.template "$PREFIX/config/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$PREFIX/data"
  chmod 600 "$PREFIX/config/chatto.toml"
fi
cp config/Caddyfile "$PREFIX/config/Caddyfile"
cp landing/index.html "$PREFIX/landing/index.html"
cp lib/common.sh "$PREFIX/lib/common.sh"
cp bin/status "$PREFIX/bin/status"
cp services/joind.py services/bonjour.sh "$PREFIX/services/"
chmod +x "$PREFIX/bin/status" "$PREFIX/services/joind.py" \
  "$PREFIX/services/bonjour.sh"

if [ "$SYSTEM" = 1 ]; then
  chown "$EBOX_USER" "$PREFIX/config/chatto.toml"
  chown -R "$EBOX_USER" "$PREFIX/data" "$PREFIX/log"

  echo "==> Installing always-on launchd services"
  for t in config/org.emergencybox.*.plist.template; do
    out="/Library/LaunchDaemons/$(basename "${t%.template}")"
    render_template "$t" "$out" "EBOX_USER=$EBOX_USER"
  done
  cp config/org.emergencybox.caddy.plist /Library/LaunchDaemons/
  chown root:wheel /Library/LaunchDaemons/org.emergencybox.*.plist
  chmod 644 /Library/LaunchDaemons/org.emergencybox.*.plist
  for l in chatto joind caddy bonjour; do
    launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
    launchctl enable "system/org.emergencybox.$l" 2>/dev/null || true
    launchctl bootstrap system "/Library/LaunchDaemons/org.emergencybox.$l.plist"
  done

  echo "==> Pre-authorizing binaries with the application firewall"
  fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  for b in /opt/homebrew/bin/caddy /opt/homebrew/bin/chatto; do
    "$fw" --add "$b" >/dev/null || true
    "$fw" --unblockapp "$b" >/dev/null || true
  done

  echo "==> Waiting for chatto"
  deadline=$((SECONDS + 60))
  until curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
    ((SECONDS < deadline)) || { echo "chatto did not start; see $PREFIX/log" >&2; exit 1; }
    sleep 1
  done
  if [ ! -f "$PREFIX/config/operator-credentials.txt" ]; then
    echo "==> Creating operator (admin) account"
    op_pw=$(openssl rand -base64 12)
    if printf '%s' "$op_pw" | chatto operator \
      -c "$PREFIX/config/chatto.toml" user create \
      --login operator --password-stdin --verified-email operator@chat.lan; then
      printf 'login: operator\npassword: %s\n' "$op_pw" \
        >"$PREFIX/config/operator-credentials.txt"
      chmod 600 "$PREFIX/config/operator-credentials.txt"
      chown "$EBOX_USER" "$PREFIX/config/operator-credentials.txt"
    else
      echo "WARNING: operator account creation failed; re-run install" >&2
    fi
  fi
  cat <<EOF

Install complete — the chat is live and survives reboots.
  Chat     : http://chat.local
  Sign up  : http://chat.local/join
  Status   : $PREFIX/bin/status
  Admin    : $PREFIX/config/operator-credentials.txt
Reserve this Mac's IP in your router's DHCP settings so the printed
QR fallback stays valid.
EOF
else
  echo "Install complete (no-system mode)."
fi

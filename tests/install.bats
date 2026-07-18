#!/usr/bin/env bats
load helpers

setup_file() {
  export PREFIX
  PREFIX=$(mktemp -d)
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
}

@test "renders chatto.toml with distinct generated secrets" {
  grep -qE "cookie_signing_secret = '[0-9a-f]{64}'" "$PREFIX/config/chatto.toml"
  s=$(grep -oE "[0-9a-f]{64}" "$PREFIX/config/chatto.toml" | sort -u | wc -l)
  [ "$s" -ge 4 ]
}

@test "chatto.toml is not world readable" {
  perms=$(stat -f '%Lp' "$PREFIX/config/chatto.toml")
  [ "$perms" = "600" ]
}

@test "rendered dnsmasq config passes dnsmasq --test" {
  run dnsmasq --test --conf-file="$PREFIX/config/dnsmasq.conf"
  [ "$status" -eq 0 ]
}

@test "rendered dnsmasq config binds the real wifi device" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  grep -qx "interface=$(detect_wifi_device)" "$PREFIX/config/dnsmasq.conf"
}

@test "caddyfile and portal installed and valid" {
  [ -f "$PREFIX/landing/index.html" ]
  run caddy validate --config "$PREFIX/config/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ]
}

@test "install is idempotent and keeps existing secrets" {
  before=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
  after=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  [ "$before" = "$after" ]
}

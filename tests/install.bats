#!/usr/bin/env bats
load helpers

setup_file() {
  export PREFIX HOMEBREW_NO_AUTO_UPDATE=1
  PREFIX=$(mktemp -d)
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
}

@test "renders chatto.toml with distinct secrets, registration disabled, no smtp" {
  grep -qE "cookie_signing_secret = '[0-9a-f]{64}'" "$PREFIX/config/chatto.toml"
  s=$(grep -oE "[0-9a-f]{64}" "$PREFIX/config/chatto.toml" | sort -u | wc -l)
  [ "$s" -ge 4 ]
  grep -q 'direct_registration = false' "$PREFIX/config/chatto.toml"
  ! grep -q '\[smtp\]' "$PREFIX/config/chatto.toml"
}

@test "chatto.toml is not world readable" {
  perms=$(stat -f '%Lp' "$PREFIX/config/chatto.toml")
  [ "$perms" = "600" ]
}

@test "services and portal installed" {
  [ -x "$PREFIX/services/joind.py" ]
  [ -x "$PREFIX/services/bonjour.sh" ]
  [ -x "$PREFIX/bin/status" ]
  [ -f "$PREFIX/landing/index.html" ]
  [ -f "$PREFIX/lib/common.sh" ]
}

@test "caddyfile installed and valid" {
  run caddy validate --config "$PREFIX/config/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ]
}

@test "data dir is private" {
  perms=$(stat -f '%Lp' "$PREFIX/data")
  [ "$perms" = "700" ]
}

@test "install is idempotent and keeps existing secrets" {
  before=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
  after=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  [ "$before" = "$after" ]
}

@test "custom prefix is refused for system installs" {
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix /tmp/nope
  [ "$status" -eq 2 ]
}

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
  grep -q 'port = 8080' "$PREFIX/config/chatto.toml"
}

@test "chatto.toml is not world readable" {
  perms=$(stat -f '%Lp' "$PREFIX/config/chatto.toml")
  [ "$perms" = "600" ]
}

@test "renders bots.ini with distinct secrets, private" {
  grep -q 'name = 台北' "$PREFIX/config/bots.ini"
  n=$(grep -oE 'password = [0-9a-f]{32}' "$PREFIX/config/bots.ini" |
    sort -u | wc -l)
  [ "$n" -eq 3 ]
  perms=$(stat -f '%Lp' "$PREFIX/config/bots.ini")
  [ "$perms" = "600" ]
}

@test "services and portal installed" {
  [ -x "$PREFIX/services/joind.py" ]
  [ -x "$PREFIX/services/bonjour.sh" ]
  [ -x "$PREFIX/services/seed.py" ]
  [ -x "$PREFIX/services/botd.py" ]
  [ -f "$PREFIX/services/chatto_api.py" ]
  [ -x "$PREFIX/bin/status" ]
  [ -f "$PREFIX/landing/index.html" ]
  [ -f "$PREFIX/landing/welcome.html" ]
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
  bots_before=$(grep 'password = ' "$PREFIX/config/bots.ini")
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
  after=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  [ "$before" = "$after" ]
  bots_after=$(grep 'password = ' "$PREFIX/config/bots.ini")
  [ "$bots_before" = "$bots_after" ]
}

@test "custom prefix is refused for system installs" {
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix /tmp/nope
  [ "$status" -eq 2 ]
}

@test "all five launchd plists pass plutil -lint" {
  local tmp
  tmp=$(mktemp -d)
  # shellcheck source=lib/common.sh
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  for t in "$BATS_TEST_DIRNAME"/../config/org.emergencybox.*.plist.template; do
    render_template "$t" "$tmp/$(basename "${t%.template}")" "EBOX_USER=dummy"
  done
  cp "$BATS_TEST_DIRNAME/../config/org.emergencybox.caddy.plist" "$tmp/"
  for p in "$tmp"/org.emergencybox.*.plist; do
    run plutil -lint "$p"
    [ "$status" -eq 0 ]
  done
}

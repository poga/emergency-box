#!/usr/bin/env bats
load helpers

setup_file() {
  export EBOX_TEST_DIR CADDY_URL="http://127.0.0.1:18080"
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
  EBOX_HTTP_PORT=18080 EBOX_ROOT="$BATS_TEST_DIRNAME/.." \
    caddy start --config "$BATS_TEST_DIRNAME/../config/Caddyfile" \
    --adapter caddyfile --pidfile "$EBOX_TEST_DIR/caddy.pid"
  wait_for_url "$CADDY_URL" 15
}

teardown_file() {
  kill "$(cat "$EBOX_TEST_DIR/caddy.pid")" 2>/dev/null || true
  stop_chatto_stack "$EBOX_TEST_DIR"
}

@test "host chat.lan proxies to chatto" {
  run curl -fsS -H 'Host: chat.lan' "$CADDY_URL/healthz"
  echo "$output" | jq -e '.status == "ok"'
}

@test "host mail.lan proxies to mailpit UI" {
  run curl -fsS -H 'Host: mail.lan' "$CADDY_URL/api/v1/info"
  [ "$status" -eq 0 ]
}

@test "captive probe host gets portal page, not Success" {
  run curl -fsS -H 'Host: captive.apple.com' "$CADDY_URL/hotspot-detect.html"
  [[ "$output" == *"Emergency"* ]]
  [[ "$output" != *"<BODY>Success</BODY>"* ]]
}

@test "any other host and path gets portal page" {
  run curl -fsS -H 'Host: connectivitycheck.gstatic.com' "$CADDY_URL/generate_204"
  [[ "$output" == *"Emergency"* ]]
}

@test "portal host /auth/* reaches chatto same-origin" {
  run curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Host: whatever.example' -H 'Content-Type: application/json' \
    -d '{}' "$CADDY_URL/auth/register"
  [ "$output" = "400" ]
}

@test "portal host /mailapi/* reaches mailpit API same-origin" {
  run curl -fsS -H 'Host: whatever.example' "$CADDY_URL/mailapi/api/v1/info"
  [ "$status" -eq 0 ]
}

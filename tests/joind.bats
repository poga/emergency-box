#!/usr/bin/env bats
load helpers

JOIND=http://127.0.0.1:18081

setup_file() {
  export EBOX_TEST_DIR
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
  require_port_free 18081
  JOIND_PORT=18081 \
    JOIND_CHATTO=$(command -v chatto) \
    JOIND_CONFIG="$EBOX_TEST_DIR/chatto.toml" \
    python3 "$BATS_TEST_DIRNAME/../services/joind.py" \
    >"$EBOX_TEST_DIR/joind.log" 2>&1 &
  echo $! >"$EBOX_TEST_DIR/joind.pid"
  local deadline=$((SECONDS + 15))
  until [ "$(curl -s -o /dev/null -w '%{http_code}' $JOIND/join)" = "405" ]; do
    ((SECONDS < deadline)) || return 1
    sleep 0.3
  done
}

teardown_file() {
  kill "$(cat "$EBOX_TEST_DIR/joind.pid")" 2>/dev/null || true
  stop_chatto_stack "$EBOX_TEST_DIR"
}

@test "creates an account that can really log in" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"joinuser","password":"emergency123"}'
  [ "$output" = "201" ]
  run curl -fsS -X POST http://127.0.0.1:18082/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"login":"joinuser","password":"emergency123"}'
  echo "$output" | jq -e '.user.login == "joinuser"'
}

@test "duplicate login returns 409" {
  curl -s -o /dev/null -X POST "$JOIND/join" -H 'Content-Type: application/json' \
    -d '{"login":"dupuser","password":"emergency123"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"dupuser","password":"emergency123"}'
  [ "$output" = "409" ]
}

@test "short password returns 400" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"shortpw","password":"short"}'
  [ "$output" = "400" ]
}

@test "invalid login characters return 400" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"Bad Name!","password":"emergency123"}'
  [ "$output" = "400" ]
}

@test "chatto email registration path is closed" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    http://127.0.0.1:18082/auth/register -H 'Content-Type: application/json' \
    -d '{"email":"x@chat.lan"}'
  [ "$output" = "403" ]
}

@test "non-dict json body returns 400" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' -d '[1,2,3]'
  [ "$output" = "400" ]
}

@test "oversized body returns 413" {
  local payload
  payload=$(python3 -c 'print("x" * 5000)')
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' -d "$payload"
  [ "$output" = "413" ]
}

# keep last: drains the rate-limit bucket, would skew earlier tests
@test "rate limit trips under rapid requests" {
  local i codes=""
  for i in $(seq 1 14); do
    codes+=$(curl -s -o /dev/null -w '%{http_code} ' -X POST "$JOIND/join" \
      -H 'Content-Type: application/json' \
      -d '{"login":"a","password":"short"}')
  done
  [[ "$codes" == *"429"* ]]
}

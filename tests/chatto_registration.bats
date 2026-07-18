#!/usr/bin/env bats
load helpers

setup_file() {
  export EBOX_TEST_DIR
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
}

teardown_file() { stop_chatto_stack "$EBOX_TEST_DIR"; }

@test "full offline registration round-trip then login" {
  email="testuser@chat.lan"
  run curl -fsS -X POST http://127.0.0.1:8080/auth/register \
    -H 'Content-Type: application/json' -d "{\"email\":\"$email\"}"
  [ "$status" -eq 0 ]

  code=""
  deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)) && [ -z "$code" ]; do
    id=$(curl -fsS "http://127.0.0.1:8025/api/v1/search?query=to:%22$email%22" |
      jq -r '.messages[0].ID // empty')
    if [ -n "$id" ]; then
      code=$(curl -fsS "http://127.0.0.1:8025/api/v1/message/$id" |
        jq -r .Text | grep -oE '[0-9]{6}' | head -1)
    fi
    [ -z "$code" ] && sleep 0.5
  done
  [ -n "$code" ]

  token=$(curl -fsS -X POST http://127.0.0.1:8080/auth/register/verify-code \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"code\":\"$code\"}" | jq -r .completionToken)
  [ -n "$token" ] && [ "$token" != "null" ]

  run curl -fsS -X POST http://127.0.0.1:8080/auth/register/complete \
    -H 'Content-Type: application/json' \
    -d "{\"token\":\"$token\",\"login\":\"testuser\",\"password\":\"emergency123\",\"passwordConfirmation\":\"emergency123\"}"
  [ "$status" -eq 0 ]

  run curl -fsS -X POST http://127.0.0.1:8080/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"login":"testuser","password":"emergency123"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.user.login == "testuser"'
}

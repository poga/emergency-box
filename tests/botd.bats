#!/usr/bin/env bats
load helpers

setup_file() {
  export STACK FIXDIR CONF STATE OPTOK
  STACK="$BATS_FILE_TMPDIR/stack"
  start_chatto_stack "$STACK"
  create_operator "$STACK"
  run python3 "$BATS_TEST_DIRNAME/../services/seed.py" \
    --url http://127.0.0.1:18082 \
    --credentials "$STACK/operator-credentials.txt"
  [ "$status" -eq 0 ]
  for b in weatherbot newsbot alertbot; do
    printf 'botpass123' | chatto operator -c "$STACK/chatto.toml" \
      user create --login "$b" --password-stdin >/dev/null
  done
  FIXDIR="$BATS_FILE_TMPDIR/fixtures"
  mkdir -p "$FIXDIR"
  cp "$BATS_TEST_DIRNAME/fixtures/openmeteo.json" \
    "$BATS_TEST_DIRNAME/fixtures/pts.xml" \
    "$BATS_TEST_DIRNAME/fixtures/gnews.xml" "$FIXDIR/"
  # shellcheck source=lib/common.sh
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  ts=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')
  render_template "$BATS_TEST_DIRNAME/fixtures/ncdr-1.xml.template" \
    "$FIXDIR/ncdr.xml" "TS=$ts"
  require_port_free 18090
  python3 -m http.server 18090 --directory "$FIXDIR" >/dev/null 2>&1 &
  echo $! >"$STACK/httpfix.pid"
  wait_for_url http://127.0.0.1:18090/openmeteo.json 10
  STATE="$BATS_FILE_TMPDIR/botd-state.json"
  CONF="$BATS_FILE_TMPDIR/bots.ini"
  write_bots_ini "$CONF" "$STATE"
  OPTOK=$(chatto_token boxadmin testoppass123)
}

write_bots_ini() { # CONF_PATH STATE_PATH
  cat >"$1" <<EOF
[botd]
chatto_url = http://127.0.0.1:18082
state_file = $2
offline_after = 1

[location]
name = 台北
latitude = 25.04
longitude = 121.51

[weather]
login = weatherbot
password = botpass123
room = weather
post_times = 00:00
url = http://127.0.0.1:18090/openmeteo.json

[news]
login = newsbot
password = botpass123
room = news
interval = 3600
max_items = 10
feeds = http://127.0.0.1:18090/pts.xml
    http://127.0.0.1:18090/gnews.xml

[alerts]
login = alertbot
password = botpass123
room = alerts
interval = 300
regions =
feed = http://127.0.0.1:18090/ncdr.xml
EOF
}

teardown_file() {
  [ -f "$STACK/httpfix.pid" ] &&
    kill "$(cat "$STACK/httpfix.pid")" 2>/dev/null || true
  stop_chatto_stack "$STACK"
}

@test "botd --once posts a Chinese weather digest to #weather" {
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$status" -eq 0 ]
  wid=$(room_id_by_name "$OPTOK" weather)
  wait_for_room_message "$OPTOK" "$wid" "天氣預報" 15
  [ "$(count_body_matches "$OPTOK" "$wid" "26–33°C")" -ge 1 ]
  [ "$(count_body_matches "$OPTOK" "$wid" "降雨機率 100%")" -ge 1 ]
}

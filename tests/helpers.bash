#!/bin/bash

wait_for_url() { # URL DEADLINE_SECS ; polls until 2xx or deadline
  local url=$1 deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    curl -fsS --max-time 2 -o /dev/null "$url" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "timeout waiting for $url" >&2
  return 1
}

require_port_free() {
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $1 is busy; stop that service to run this test" >&2
    return 1
  fi
}

start_chatto_stack() { # DIR ; starts a real chatto on the dedicated test port
  local dir=$1
  require_port_free 18082 || return 1
  mkdir -p "$dir/data"
  # chatto refuses a group/other-accessible socket dir
  chmod 700 "$dir/data"
  # shellcheck source=lib/common.sh
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/chatto.toml.template" \
    "$dir/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$dir/data" "CHATTO_PORT=18082"
  cd "$dir" || return 1
  chatto run -c "$dir/chatto.toml" >"$dir/chatto.log" 2>&1 &
  echo $! >"$dir/chatto.pid"
  cd - >/dev/null || return 1
  wait_for_url http://127.0.0.1:18082/healthz 30
}

stop_chatto_stack() { # DIR ; kills stack, waits for exit so ports free up
  local dir=$1 f pid deadline
  for f in "$dir"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f")
    kill "$pid" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 0.2
    done
  done
}

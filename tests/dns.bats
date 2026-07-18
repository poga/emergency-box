#!/usr/bin/env bats
load helpers

setup_file() {
  export DNS_DIR
  DNS_DIR=$(mktemp -d)
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/dnsmasq-dns.conf.template" \
    "$DNS_DIR/dns.conf" "BOX_IP=10.87.0.1"
  dnsmasq --conf-file="$DNS_DIR/dns.conf" --port=15353 \
    --listen-address=127.0.0.1 --no-daemon >"$DNS_DIR/dnsmasq.log" 2>&1 &
  echo $! >"$DNS_DIR/dnsmasq.pid"
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    dig +short +time=1 +tries=1 -p 15353 probe.example @127.0.0.1 |
      grep -qx 10.87.0.1 && return 0
    sleep 0.3
  done
  return 1
}

teardown_file() { kill "$(cat "$DNS_DIR/dnsmasq.pid")" 2>/dev/null || true; }

@test "wildcard DNS answers any name with the box IP" {
  run dig +short -p 15353 "random$RANDOM.example.com" @127.0.0.1
  [ "$output" = "10.87.0.1" ]
  run dig +short -p 15353 chat.lan @127.0.0.1
  [ "$output" = "10.87.0.1" ]
  run dig +short -p 15353 captive.apple.com @127.0.0.1
  [ "$output" = "10.87.0.1" ]
}

@test "production dnsmasq config validates" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/dnsmasq-dns.conf.template" \
    "$DNS_DIR/dnsmasq-dns.conf" "BOX_IP=10.87.0.1"
  render_template "$BATS_TEST_DIRNAME/../config/dnsmasq.conf.template" \
    "$DNS_DIR/dnsmasq.conf" "CONFIG_DIR=$DNS_DIR" \
    "WIFI_DEVICE=$(detect_wifi_device)" "DATA_DIR=$DNS_DIR" "LOG_DIR=$DNS_DIR"
  run dnsmasq --test --conf-file="$DNS_DIR/dnsmasq.conf"
  [ "$status" -eq 0 ]
}

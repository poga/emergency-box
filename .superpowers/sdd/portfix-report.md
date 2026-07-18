# Port fix report

Problem: production daemons (chatto :8080, joind :8081, caddy :80) are
always-on now, so `require_port_free` aborted `setup_file` in
tests/joind.bats and tests/caddy_routing.bats. bats treated those as
failing tests (`not ok N setup_file failed`) but still printed the
skipped-count as a warning rather than a hard stop, and on some bats
versions this false-greens. Fix: give the test stack dedicated ports
(18081 joind, 18082 chatto, 18080 caddy) so it runs fully alongside
the installed services.

## Changes per file

- **config/chatto.toml.template**: `port = 8080` -> `port = @CHATTO_PORT@`.
  Webserver `url` untouched.
- **install.sh**: `render_template` call for chatto.toml now passes
  `"CHATTO_PORT=8080"`, pinning production to its original port.
- **tests/helpers.bash** (`start_chatto_stack`): renders with
  `CHATTO_PORT=18082`, checks `require_port_free 18082`, waits on
  `http://127.0.0.1:18082/healthz`.
- **tests/joind.bats**: joind launched with `JOIND_PORT=18081` exported
  into the launch env; `require_port_free 18081`; `JOIND` base URL is
  `http://127.0.0.1:18081`. The direct `/auth/login` verification and
  the "email path closed" test now hit `127.0.0.1:18082` (the test
  chatto instance).
- **config/Caddyfile**: both chatto upstreams use
  `reverse_proxy 127.0.0.1:{$EBOX_CHATTO_PORT:8080}` and the joinapi
  route uses `reverse_proxy 127.0.0.1:{$EBOX_JOIND_PORT:8081}`. No env
  set (production plist) keeps the 8080/8081 defaults.
- **tests/caddy_routing.bats**: joind started with `JOIND_PORT=18081`;
  caddy started with
  `EBOX_HTTP_PORT=18080 EBOX_CHATTO_PORT=18082 EBOX_JOIND_PORT=18081
  EBOX_ROOT=...`; `caddy start` output redirected to a log file
  (never piped) so it can't hang stdout. Routing assertions unchanged.
- **tests/scripts.bats**: "bonjour publisher makes chat.local resolve"
  now does `kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null
  || true` to reap the backgrounded publisher quietly, silencing the
  bats job-control "Terminated" line.
- **tests/install.bats**: added `grep -q 'port = 8080'
  "$PREFIX/config/chatto.toml"` to the existing render test, pinning
  the production port in the installed config.
- **bin/status**, production plists: untouched — still 8080/8081/80.

## Verification

`./test.sh` on this machine, with production chatto/joind/caddy
daemons live on 8080/8081/80:

```
1..26
ok 1 default route reaches chatto
ok 2 /join serves the portal page
ok 3 /join/anything still serves the portal page
ok 4 /joinapi reaches joind
ok 5 chatto UI is the front page
ok 6 renders chatto.toml with distinct secrets, registration disabled, no smtp
ok 7 chatto.toml is not world readable
ok 8 services and portal installed
ok 9 caddyfile installed and valid
ok 10 data dir is private
ok 11 install is idempotent and keeps existing secrets
ok 12 custom prefix is refused for system installs
ok 13 all four launchd plists pass plutil -lint
ok 14 creates an account that can really log in
ok 15 duplicate login returns 409
ok 16 short password returns 400
ok 17 invalid login characters return 400
ok 18 chatto email registration path is closed
ok 19 non-dict json body returns 400
ok 20 oversized body returns 413
ok 21 rate limit trips under rapid requests
ok 22 status shows usage with --help
ok 23 status rejects unknown flags
ok 24 wifi detection finds a real device
ok 25 bonjour publisher script is valid and sources cleanly
ok 26 bonjour publisher makes chat.local resolve (best effort)
```

Exit code: 0. No `bats warning: Executed N instead of expected 26
tests` line. No stray "Terminated" job-control noise. Test 26 (the
live bonjour test) passed via the already-running production bonjour
publisher, as expected.

`shellcheck` (as run inside `test.sh`, the same invocation used in
the repo's shellcheck step) is clean — `test.sh` uses `set -euo
pipefail` with shellcheck as its first step, so the exit-0 run above
already proves it; confirmed by tracing with `bash -x test.sh`.

`caddy validate` with no env set (production defaults):

```
$ caddy validate --config config/Caddyfile --adapter caddyfile
{"level":"info","msg":"using config from file","file":"config/Caddyfile"}
{"level":"info","msg":"adapted config to JSON","adapter":"caddyfile"}
{"level":"info","logger":"http.auto_https","msg":"automatic HTTPS is completely disabled for server","server_name":"srv0"}
{"level":"info","logger":"tls.cache.maintenance","msg":"started background certificate maintenance"}
{"level":"info","logger":"http","msg":"servers shutting down with eternal grace period"}
{"level":"info","logger":"tls.cache.maintenance","msg":"stopped background certificate maintenance"}
Valid configuration
```

Exit code: 0.

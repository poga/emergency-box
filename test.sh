#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
files=$(find . -name '*.sh' -not -path './.git/*'; find bin -type f 2>/dev/null || true)
# shellcheck disable=SC2086
shellcheck $files lib/common.sh tests/helpers.bash
bats tests/

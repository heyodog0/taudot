#!/usr/bin/env bash
# Run every protocol test against the local CE and print a pass/fail line per test. Each test uses its own project.
#   harness/tests/run.sh [name ...]      e.g. run.sh emoji classic-basics
# TAUDOT_ENV_FILE picks the env file (default docker/.env.test).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tests=("$@")
[ ${#tests[@]} -eq 0 ] && tests=(classic-basics historyot-version historyot-stale-browser "historyot-stale-browser --classic" historyot-snapshot emoji upload-filetypes migration session entity-events files cursors chat-settings)
fail=0
for t in "${tests[@]}"; do
  name="${t%% *}"; args=""; [[ "$t" == *" "* ]] && args="${t#* }"
  out="$(node "$here/$name.ts" $args 2>&1)"
  if [ $? -eq 0 ]; then echo "pass  $t"; else echo "FAIL  $t"; echo "$out" | sed 's/^/      /'; fail=1; fi
done
exit $fail

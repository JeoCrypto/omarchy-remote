#!/bin/bash
# omarchy-remote: developed by JeoCrypto
# Headless checks for omarchy-vnc: login outcomes and exit codes, against a local test server.
set -u
cd "$(dirname "$0")/.."
vnc=./omarchy-vnc; srv=test/testserver
fail=0
check() {  # check <name> <expected exit> <command...>
  local name="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [[ $got == "$want" ]]; then echo "ok   $name (exit $got)"; else echo "FAIL $name: expected exit $want, got $got"; fail=1; fi
}
port=$((20000 + RANDOM % 20000))
"$srv" "$port" secret >/dev/null 2>&1 & pid=$!
sleep 1
check "right password"   0 bash -c "echo secret  | $vnc --host 127.0.0.1 --port $port --check"
check "wrong password"   2 bash -c "echo wrongpw | $vnc --host 127.0.0.1 --port $port --check"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
sleep 0.5
check "nothing listening" 3 bash -c "echo x | $vnc --host 127.0.0.1 --port $port --check"
(( fail )) && echo "some checks failed" || echo "all checks passed"
exit $fail

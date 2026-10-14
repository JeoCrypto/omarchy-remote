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
# --- remote-desktop-status: ssh config import (stub tailscale/hyprctl, throwaway config) ---------------
tmp=$(mktemp -d)
cat > "$tmp/tailscale" <<'EOS'
#!/bin/sh
echo '{"Peer":{"a":{"DNSName":"srv.tail.ts.net.","HostName":"srv","OS":"linux","Online":true,"TailscaleIPs":["100.64.0.2"]}}}'
EOS
printf '#!/bin/sh\necho "[]"\n' > "$tmp/hyprctl"
chmod +x "$tmp/tailscale" "$tmp/hyprctl"
cat > "$tmp/ssh_config" <<'EOS'
Host *
    ServerAliveInterval 30
Host srvalias
    HostName srv
Host extra other
    HostName 127.0.0.1
    User bob
EOS
echo '[]' > "$tmp/conf.json"
out=$(PATH="$tmp:$PATH" REMOTE_CONF="$tmp/conf.json" REMOTE_SSH_CONFIG="$tmp/ssh_config" bin/remote-desktop-status --all)
ids=$(jq -r 'map(.id) | sort | join(",")' <<<"$out")
[[ $ids == "extra,other,srv" ]] && echo "ok   ssh hosts listed, Tailscale duplicate merged" || { echo "FAIL ssh ids: $ids"; fail=1; }
[[ $(jq -r '.[] | select(.id == "srv") | .ssh' <<<"$out") == srvalias ]] && echo "ok   alias attached to its Tailscale machine" || { echo "FAIL alias"; fail=1; }
[[ $(jq -r '.[] | select(.id == "extra") | "\(.os) \(.user)"' <<<"$out") == "ssh bob" ]] && echo "ok   ssh-only host has os ssh and its user" || { echo "FAIL ssh-only fields"; fail=1; }
rm -rf "$tmp"
(( fail )) && echo "some checks failed" || echo "all checks passed"
exit $fail

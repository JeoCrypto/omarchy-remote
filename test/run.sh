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
# --- remote-sessions: argument checks and unknown computer (no ssh needed) ---------------------------
check "bad session name"      2 env PATH="$tmp:$PWD/bin:$PATH" REMOTE_CONF="$tmp/conf.json" REMOTE_SSH_CONFIG="$tmp/ssh_config" bin/remote-sessions kill srv "a b"
check "missing computer"      2 env PATH="$tmp:$PWD/bin:$PATH" bin/remote-sessions list
check "unknown computer"      4 env PATH="$tmp:$PWD/bin:$PATH" REMOTE_CONF="$tmp/conf.json" REMOTE_SSH_CONFIG="$tmp/ssh_config" bin/remote-sessions list nosuchmachine
# --- remote-desktop-status: no window titles or config on any command line ----------------------------
# A command line is readable by every local user in /proc/<pid>/cmdline, and the bar runs this script every
# few seconds. Wrap jq to record every argument it gets, and make sure no private data appears in them.
realjq=$(command -v jq)
cat > "$tmp/hyprctl" <<'EOS'
#!/bin/sh
echo '[{"address":"0x1","title":"SECRET-WINDOW-TITLE","workspace":{"name":"srv"}}]'
EOS
cat > "$tmp/jq" <<EOS
#!/bin/sh
printf '%s\n' "\$@" >> "$tmp/jq-args"
exec "$realjq" "\$@"
EOS
chmod +x "$tmp/hyprctl" "$tmp/jq"
echo '[{"host":"srv","label":"SECRET-LABEL","user":"SECRET-USER"}]' > "$tmp/conf.json"
: > "$tmp/jq-args"
out=$(PATH="$tmp:$PATH" REMOTE_CONF="$tmp/conf.json" REMOTE_SSH_CONFIG="$tmp/ssh_config" bin/remote-desktop-status --all)
if grep -qE 'SECRET-|bob|srvalias' "$tmp/jq-args"; then echo "FAIL private data passed on a jq command line"; fail=1; else echo "ok   no private data on jq command lines"; fi
[[ $(jq -r '.[] | select(.id == "srv") | "\(.open) \(.label)"' <<<"$out") == "true SECRET-LABEL" ]] && echo "ok   open flag and config still applied" || { echo "FAIL open/label: $out"; fail=1; }

# --- remote-manage: cache + state directories and files are owner-only -------------------------------
# Host names, user names and local status in ~/.cache/omarchy-remote and ~/.local/state/omarchy-remote are
# private to the user. Verify the dirs are 0700 and the files 0600, including the upgrade case where an
# older install already left a world-readable cache behind.
mode() { stat -c '%a' "$1" 2>/dev/null; }

home=$(mktemp -d); chmod 755 "$home"
cache="$home/cache/omarchy-remote"
state="$home/state/omarchy-remote"
# Simulate an older install: cache dir and status.json world-readable, state dir and starred too.
mkdir -p "$cache" "$state"; chmod 755 "$cache" "$state"
echo '[{"id":"srv","host":"srv","label":"srv","online":true,"open":false,"hidden":false,"os":"linux"}]' > "$cache/status.json"
chmod 644 "$cache/status.json"
: > "$state/starred"; chmod 644 "$state/starred"

run_rm() {
  env -i PATH="$tmp:$PWD/bin:/usr/bin:/bin" HOME="$home" \
    XDG_CACHE_HOME="$home/cache" XDG_STATE_HOME="$home/state" \
    REMOTE_CONF="$tmp/conf.json" REMOTE_SSH_CONFIG="$tmp/ssh_config" \
    bin/remote-manage "$@" >/dev/null 2>&1
}

# A read-only sub-command exercises the dir/file setup without needing a TTY.
run_rm rows || true
[[ $(mode "$cache") == 700 ]]                  && echo "ok   cache dir repaired to 0700"              || { echo "FAIL cache dir perms: $(mode "$cache")"; fail=1; }
[[ $(mode "$state") == 700 ]]                  && echo "ok   state dir repaired to 0700"              || { echo "FAIL state dir perms: $(mode "$state")"; fail=1; }
[[ $(mode "$cache/status.json") == 600 ]]      && echo "ok   existing status.json repaired to 0600"   || { echo "FAIL status.json perms: $(mode "$cache/status.json")"; fail=1; }
[[ $(mode "$state/starred") == 600 ]]          && echo "ok   starred file is 0600"                    || { echo "FAIL starred perms: $(mode "$state/starred")"; fail=1; }

# rows-fresh writes a brand-new status.json via a temp file + rename; the result must be 0600 without needing a chmod.
rm -f "$cache/status.json"
run_rm rows-fresh || true
if [[ -e $cache/status.json ]]; then
  [[ $(mode "$cache/status.json") == 600 ]]    && echo "ok   fresh status.json created as 0600"       || { echo "FAIL fresh status.json perms: $(mode "$cache/status.json")"; fail=1; }
else
  echo "FAIL rows-fresh did not write status.json"; fail=1
fi

# Also check: a brand-new install (no pre-existing dirs) still ends up with 0700 dirs.
home2=$(mktemp -d); chmod 755 "$home2"
env -i PATH="$tmp:$PWD/bin:/usr/bin:/bin" HOME="$home2" \
  XDG_CACHE_HOME="$home2/cache" XDG_STATE_HOME="$home2/state" \
  REMOTE_CONF="$tmp/conf.json" REMOTE_SSH_CONFIG="$tmp/ssh_config" \
  bin/remote-manage rows >/dev/null 2>&1 || true
[[ $(mode "$home2/cache/omarchy-remote") == 700 ]] && echo "ok   fresh install creates cache dir 0700" || { echo "FAIL fresh cache dir perms: $(mode "$home2/cache/omarchy-remote")"; fail=1; }
[[ $(mode "$home2/state/omarchy-remote") == 700 ]] && echo "ok   fresh install creates state dir 0700" || { echo "FAIL fresh state dir perms: $(mode "$home2/state/omarchy-remote")"; fail=1; }
rm -rf "$home" "$home2"

rm -rf "$tmp"
(( fail )) && echo "some checks failed" || echo "all checks passed"
exit $fail

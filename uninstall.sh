#!/bin/bash
# omarchy-remote: developed by JeoCrypto
# omarchy-remote uninstaller.
#
#   ./uninstall.sh            remove programs, plugins and Hyprland edits (keeps your computer list and passwords)
#   ./uninstall.sh --purge    also delete the computer list, saved passwords and state
#   ./uninstall.sh --dry-run  show what would happen
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"; SHARE="$PREFIX/share/omarchy-remote"; STATE="$PREFIX/state/omarchy-remote"
HYPR="$HOME/.config/hypr"; PLUGINS="$HOME/.config/omarchy/plugins"
CONF="$HOME/.config/omarchy/remote-computers.json"
stamp=$(date +%Y%m%d-%H%M%S)

dry=0; purge=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --purge) purge=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
run() { if (( dry )); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

# remove_block FILE NAME : drop "-- NAME: start .. -- NAME: end"
remove_block() {
  local file="$1" name="$2"
  [[ -f $file ]] || return 0
  grep -qF -- "-- $name: start" "$file" || return 0
  (( dry )) && { echo "    [dry-run] remove block '$name' from $file"; return; }
  cp -p "$file" "$file.bak.$stamp"
  local tmp; tmp=$(mktemp)
  awk -v s="-- $name: start" -v e="-- $name: end" '$0==s{skip=1; next} $0==e{skip=0; next} !skip' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}

say "Closing any open remote windows"
run pkill -x sdl-freerdp3 || true
run pkill -x omarchy-vnc || true

say "Removing the plugins"
for p in omarchy-remote omarchy-remote.chips omarchy-remote.picker; do
  if [[ -d $PLUGINS/$p ]]; then run omarchy plugin remove "$p" --yes || run rm -rf "$PLUGINS/$p"; fi
done

say "Restoring Hyprland (this also gives Super+F back to Omarchy)"
remove_block "$HYPR/hyprland.lua" "omarchy-remote"
remove_block "$HYPR/bindings.lua" "omarchy-remote"
run rm -f "$HYPR/remote.lua"
if (( ! dry )); then hyprctl reload >/dev/null 2>&1 || true; fi

say "Removing programs"
for f in remote-desktop remote-desktop-setup remote-desktop-status remote-fullscreen remote-manage omarchy-vnc; do run rm -f "$BIN/$f"; done
run rm -rf "$SHARE"

if (( purge )); then
  say "Purging settings, saved passwords and state"
  run rm -f "$CONF"
  run rm -rf "$STATE" "$HOME/.cache/omarchy-remote"
  if command -v secret-tool >/dev/null 2>&1; then
    # one keyring entry per computer: service=omarchy-remote
    while read -r host; do
      [[ -n $host ]] && run secret-tool clear service omarchy-remote name "$host"
    done < <(secret-tool search --all service omarchy-remote 2>/dev/null | sed -n 's/^attribute\.name = //p')
  fi
else
  echo "    kept: $CONF and your saved passwords (use --purge to delete them)"
fi

if (( ! dry )) && command -v omarchy >/dev/null 2>&1; then omarchy restart shell >/dev/null 2>&1 || true; fi
say "Done. (Mac displays are never left changed: the helper restores on disconnect and its changes end at logout.)"

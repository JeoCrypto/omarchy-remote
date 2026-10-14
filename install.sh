#!/bin/bash
# omarchy-remote: developed by JeoCrypto
# omarchy-remote installer. Run it from a clone, or from ~/.config/omarchy/plugins/omarchy-remote after
# 'omarchy plugin add https://github.com/JeoCrypto/omarchy-remote.git'.
#
#   ./install.sh              install (or update in place)
#   ./install.sh --dry-run    show what would happen, change nothing
#   ./install.sh --yes        do not ask for confirmation
#   ./install.sh --no-build   skip compiling omarchy-vnc (use a prebuilt binary in ./omarchy-vnc)
#
# Everything lives in your home directory. Every file we edit gets a timestamped backup, our edits are
# wrapped in "omarchy-remote: start/end" markers so uninstall.sh can remove them cleanly, and if Hyprland
# rejects the new config the previous files are restored.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
SHARE="$PREFIX/share/omarchy-remote"
HYPR="$HOME/.config/hypr"
PLUGINS="$HOME/.config/omarchy/plugins"
CONF="$HOME/.config/omarchy/remote-computers.json"
STATE="$PREFIX/state/omarchy-remote"
stamp=$(date +%Y%m%d-%H%M%S)

dry=0; build=1; yes=0
for a in "$@"; do
  case "$a" in
    --yes|-y) yes=1 ;;
    --dry-run) dry=1 ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
run()  { if (( dry )); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

# ---- 0. consent ---------------------------------------------------------------------------------
if (( ! dry && ! yes )) && [[ -r /dev/tty ]]; then
  cat <<EOF
This will change, in your home directory only:
  - install programs into $BIN and a plugin into $PLUGINS/omarchy-remote
  - add one marked block to ~/.config/hypr/hyprland.lua and one to ~/.config/hypr/bindings.lua
    (new keys: Super+R, Super+Shift+R, and Super+F, which replaces Omarchy's "Full screen" key with one that
     behaves the same for normal windows)
  - create ~/.config/omarchy/remote-computers.json if it does not exist
Every edited file is backed up first; ./uninstall.sh reverts all of it. (Use --dry-run to preview.)
EOF
  read -r -p "Continue? [Y/n] " ans </dev/tty || ans=n
  [[ -z $ans || $ans == [Yy]* ]] || { echo "Nothing changed."; exit 0; }
fi

# ---- 1. dependencies ------------------------------------------------------------------------------
say "Checking dependencies"
missing=(); need_pkgs=()
need() { command -v "$1" >/dev/null 2>&1 || { missing+=("$1"); need_pkgs+=("$2"); }; }
need hyprctl hyprland
need omarchy-shell omarchy
need tailscale tailscale
need sdl-freerdp3 freerdp
need secret-tool libsecret
need jq jq
need ssh openssh
if (( build )); then
  need gcc gcc; need make make; need pkg-config pkgconf
  if command -v pkg-config >/dev/null 2>&1; then
    pkg-config --exists sdl3 2>/dev/null        || { missing+=("sdl3 (dev files)"); need_pkgs+=(sdl3); }
    pkg-config --exists libvncclient 2>/dev/null || { missing+=("libvncclient"); need_pkgs+=(libvncserver); }
  fi
fi
if (( ${#missing[@]} )); then
  echo "Missing: ${missing[*]}" >&2
  echo "Install them, then run this again:" >&2
  echo "  omarchy pkg add $(printf '%s\n' "${need_pkgs[@]}" | sort -u | tr '\n' ' ')" >&2
  exit 1
fi
note "all present"
# the manager (Super+Shift+R) also uses fzf and gum, which ship with Omarchy; warn rather than fail
for t in fzf gum; do command -v "$t" >/dev/null 2>&1 || note "optional: '$t' not found, the manager needs it (omarchy pkg add $t)"; done

# ---- 2. build the Mac viewer ------------------------------------------------------------------------
if (( build )); then
  say "Building omarchy-vnc"
  run make -C "$here" omarchy-vnc
fi
[[ -x $here/omarchy-vnc ]] || { echo "omarchy-vnc binary not found in $here" >&2; (( dry )) || exit 1; }

# ---- 3. files -----------------------------------------------------------------------------------
say "Installing programs to $BIN"
run mkdir -p "$BIN" "$SHARE" "$STATE"
for f in remote-desktop remote-desktop-setup remote-desktop-status remote-fullscreen remote-manage remote-sessions; do
  run install -m755 "$here/bin/$f" "$BIN/$f"
done
run install -m755 "$here/omarchy-vnc" "$BIN/omarchy-vnc"
run install -m644 "$here/mac/mac-display.c" "$SHARE/mac-display.c"

say "Installing the computer list (kept if it already exists)"
if [[ ! -e $CONF ]]; then
  run mkdir -p "$(dirname "$CONF")"
  if (( dry )); then note "[dry-run] create $CONF"; else echo '[]' > "$CONF"; fi
else
  note "$CONF already exists"
fi

# ---- 4. Hyprland --------------------------------------------------------------------------------
backup() { [[ -e $1 ]] && run cp -p "$1" "$1.bak.$stamp"; }

# replace_block FILE NAME CONTENT : drop any "NAME: start .. NAME: end" block, then append a fresh one
replace_block() {
  local file="$1" name="$2" content="$3"
  (( dry )) && { note "[dry-run] update block '$name' in $file"; return; }
  touch "$file"
  local tmp; tmp=$(mktemp)
  awk -v s="-- $name: start" -v e="-- $name: end" '$0==s{skip=1; next} $0==e{skip=0; next} !skip' "$file" > "$tmp"
  { cat "$tmp"; printf '\n-- %s: start\n%s\n-- %s: end\n' "$name" "$content" "$name"; } > "$file"
  rm -f "$tmp"
}

say "Configuring Hyprland (rules, Super+R, Super+F)"
backup "$HYPR/hyprland.lua"; backup "$HYPR/bindings.lua"; backup "$HYPR/remote.lua"
run install -m644 "$here/hypr/remote.lua" "$HYPR/remote.lua"

if (( ! dry )) && [[ -f $HYPR/hyprland.lua ]]; then
  # an unmarked require from an earlier hand-made setup would load the file twice
  sed -i '/^require("hypr\.remote")[[:space:]]*$/d' "$HYPR/hyprland.lua"
fi
replace_block "$HYPR/hyprland.lua" "omarchy-remote" 'require("hypr.remote")'
replace_block "$HYPR/bindings.lua" "omarchy-remote" 'o.bind("SUPER + R", "Remote computers", "omarchy-shell shell toggle omarchy-remote")
o.bind("SUPER + SHIFT + R", "Manage remote computers", "omarchy-launch-tui --app-id=org.omarchy.terminal remote-manage")
-- Super+F: same as Omarchy'"'"'s "Full screen" for normal windows; pixel-exact fullscreen for remote computers.
hl.unbind("SUPER + F")
o.bind("SUPER + F", "Full screen", "remote-fullscreen")'

if (( ! dry )); then
  hyprctl reload >/dev/null 2>&1 || true
  sleep 1
  errs=$(hyprctl configerrors 2>&1 || true)
  if [[ -n ${errs//[[:space:]]/} && $errs != ok* ]]; then
    echo "Hyprland rejected the configuration:" >&2; echo "$errs" >&2
    echo "Restoring your previous files." >&2
    for f in hyprland.lua bindings.lua remote.lua; do
      [[ -e $HYPR/$f.bak.$stamp ]] && cp -p "$HYPR/$f.bak.$stamp" "$HYPR/$f" || true
    done
    [[ -e $HYPR/remote.lua.bak.$stamp ]] || rm -f "$HYPR/remote.lua"
    hyprctl reload >/dev/null 2>&1 || true
    exit 1
  fi
  note "Hyprland accepted the configuration"
fi

# ---- 5. Omarchy shell plugins -----------------------------------------------------------------------
say "Installing the shell plugin (bar chips + Super+R picker)"
# earlier builds used other ids; remove them so nothing shows twice
for old in jeo.remote jeo.remote-picker omarchy-remote.chips omarchy-remote.picker; do
  if [[ -d $PLUGINS/$old ]]; then note "removing the old '$old'"; run omarchy plugin remove "$old" --yes || true; fi
done
if [[ $here == "$PLUGINS/omarchy-remote" ]]; then
  note "already in place (added with 'omarchy plugin add')"
else
  run rm -rf "$PLUGINS/omarchy-remote"
  run mkdir -p "$PLUGINS/omarchy-remote"
  run cp "$here/manifest.json" "$here/Chips.qml" "$here/Picker.qml" "$PLUGINS/omarchy-remote/"
fi
if (( ! dry )); then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 1
fi
run omarchy plugin enable omarchy-remote --after omarchy.workspaces || note "could not place the chips widget; add 'omarchy-remote' to your bar in ~/.config/omarchy/shell.json"
# a running shell can keep an old copy of a widget in memory; a restart is the reliable way to load it
if (( ! dry )); then omarchy restart shell >/dev/null 2>&1 || true; fi

say "Done."
cat <<EOF

  omarchy-remote, developed by JeoCrypto

  Super+R              pick a computer from your Tailscale
  Super+Shift+R        manage computers: settings, passwords, tests (a tmax-style manager)
  the bar chips        click one to open it (first click asks for the password, once)
  Super+F              fullscreen (pixel-exact for remote computers)

  Name a computer or tweak it in: $CONF   (see README.md)
  Remove everything with:         ./uninstall.sh
EOF

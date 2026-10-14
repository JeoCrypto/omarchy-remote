#!/bin/bash
# omarchy-remote: developed by JeoCrypto
# Guided setup for omarchy-remote. Safe to run again at any time.
#
#   One line, from anywhere:
#     bash <(curl -fsSL https://raw.githubusercontent.com/JeoCrypto/omarchy-remote/main/setup.sh)
#   Or from a clone / the plugin folder:   ./setup.sh
#
# It adds the plugin if needed, installs missing packages (asking first), checks Tailscale, runs install.sh
# and tells you what to do on your Windows and Mac computers. Read it before running it: it is short.
set -uo pipefail

REPO_URL="https://github.com/JeoCrypto/omarchy-remote.git"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/omarchy-remote"

b()    { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m[%s/5]\033[0m \033[1m%s\033[0m\n' "$1" "$2"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
ask()  { local a; read -r -p "  $1 [Y/n] " a </dev/tty || return 1; [[ -z $a || $a == [Yy]* ]]; }
pause() { printf '\n'; read -r -p "Press Enter to close. " _ </dev/tty || true; }
die()  { printf '\n\033[31m%s\033[0m\n' "$*" >&2; pause; exit 1; }

b "omarchy-remote setup  (developed by JeoCrypto)"
command -v omarchy >/dev/null 2>&1 || die "This needs Omarchy."

# --- 1. the plugin -------------------------------------------------------------------------------
step 1 "The plugin"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
if [[ -n $here && -f $here/manifest.json && -f $here/install.sh ]]; then
  src=$here; ok "using $src"
elif [[ -f $PLUGIN_DIR/install.sh ]]; then
  src=$PLUGIN_DIR; ok "already added: $src"
else
  ask "Add the plugin from $REPO_URL ?" || die "Nothing changed."
  omarchy plugin add "$REPO_URL" --yes || die "Could not add the plugin."
  src=$PLUGIN_DIR
  [[ -f $src/install.sh ]] || die "The plugin folder is missing: $src"
  ok "added"
fi

# --- 2. packages ---------------------------------------------------------------------------------
step 2 "Packages"
declare -A pkg=( [tailscale]=tailscale [sdl-freerdp3]=freerdp [secret-tool]=libsecret [jq]=jq [ssh]=openssh
                 [gcc]=gcc [make]=make [pkg-config]=pkgconf )
need=()
for cmd in "${!pkg[@]}"; do command -v "$cmd" >/dev/null 2>&1 || need+=("${pkg[$cmd]}"); done
command -v pkg-config >/dev/null 2>&1 && {
  pkg-config --exists sdl3 2>/dev/null         || need+=(sdl3)
  pkg-config --exists libvncclient 2>/dev/null || need+=(libvncserver)
}
if ((${#need[@]})); then
  warn "missing: ${need[*]}"
  ask "Install them now with 'omarchy pkg add'?" || die "Install them yourself:  omarchy pkg add ${need[*]}"
  omarchy pkg add "${need[@]}" || die "Package install failed."
else
  ok "all present"
fi

# --- 3. Tailscale --------------------------------------------------------------------------------
step 3 "Tailscale"
if tailscale status >/dev/null 2>&1; then
  ok "signed in; your computers will appear by themselves"
else
  warn "Tailscale is not running or not signed in. Computers on your tailnet only appear after:"
  echo "      sudo systemctl enable --now tailscaled && sudo tailscale up"
  warn "Do that after this setup if you like; nothing here depends on it."
fi

# --- 4. install ----------------------------------------------------------------------------------
step 4 "Installing"
(cd "$src" && ./install.sh) || die "install.sh failed (it restores your Hyprland files if it changed them)."

# --- 5. what is left for the computers -------------------------------------------------------------
step 5 "On the computers you want to reach"
cat <<'EOF'
  Windows 10/11 Pro  Settings > System > Remote Desktop > turn on.  Install Tailscale and sign in with the same
                     account.  Optional: run windows/keep-awake.ps1 so it stays reachable while plugged in.
  Mac                System Settings > General > Sharing > turn on Screen Sharing (and Remote Login for the
                     display-matching helper).  Install Tailscale and sign in with the same account.
  Linux              Install Tailscale and an SSH server.

  Then press Super+R (or click a chip in the bar). The first time you open a computer it asks for the user name
  and password once and keeps the password in your keyring.
EOF
b "Done."
pause

# omarchy-remote

**One-click remote desktops for [Omarchy](https://omarchy.org), built on FreeRDP and Tailscale.**

*Developed by **JeoCrypto**.*

Every Windows, Mac or Linux computer on your Tailscale network shows up in the top bar next to your workspaces
and in a `Super + R` picker. Click one and its screen opens full size on its own workspace, like switching to
workspace 3: no remote-desktop app, no toolbar, no tabs. `Super + Tab` takes you back.

- **Zero setup for new machines.** Join a computer to your tailnet and it appears by itself.
- **Windows** uses FreeRDP's own window. The remote desktop is sized to your monitor's real pixels, so it is sharp
  and resizes with the window.
- **macOS** uses `omarchy-vnc`, a tiny viewer included here (about 30 KB, built on libvncclient and SDL3), with
  Apple's normal login, a two-way clipboard, and an optional helper that matches the Mac's display to your window.
- **Linux** opens an SSH session in a terminal.
- **Passwords** live in your keyring, never in a file, log or command line.
- Omarchy shortcuts keep working inside a remote desktop (`Super` never reaches the remote machine).

> This is a wrapper around existing tools, not a new RDP implementation. The protocol work is done by
> [FreeRDP](https://www.freerdp.com) (Windows) and [libvncclient](https://libvnc.github.io) (Mac).

## Requirements

- Omarchy (Hyprland + the Omarchy shell) and [Tailscale](https://tailscale.com), signed in
- `freerdp` (provides `sdl-freerdp3`), `libsecret` (`secret-tool`), `jq`, `openssh`
- To build the Mac viewer: `gcc`, `make`, `pkgconf`, `sdl3`, `libvncserver` (already on a stock Omarchy)
- On each Windows computer: Remote Desktop turned on. On each Mac: Screen Sharing turned on.

```
omarchy pkg add freerdp libsecret jq openssh gcc make pkgconf sdl3 libvncserver
```

## Install

```
git clone <this repository> omarchy-remote && cd omarchy-remote
./install.sh --dry-run     # see exactly what it will do
./install.sh
```

The installer checks the dependencies, builds `omarchy-vnc`, installs the scripts into `~/.local/bin`, installs
two Omarchy shell plugins, and adds clearly marked blocks to `~/.config/hypr/hyprland.lua` and `bindings.lua`.
Every file it edits gets a timestamped backup, and if Hyprland rejects the result the old files are restored.

Remove everything with `./uninstall.sh` (add `--purge` to also delete your computer list and saved passwords).

## Use

| | |
|---|---|
| **Super + R** | Pick a computer (type to filter, arrows, Enter) |
| **Bar chip** | Click a computer. Dim = offline, bright = online, lit = connected |
| **Super + F** | Fullscreen toggle. Normal windows behave as before; remote windows fill the monitor without losing sharpness |
| **Super + Shift + R** | Open the manager (below) |
| **Right-click a chip, or Ctrl + D in `Super + R`** | Disconnect: closes the window; the computer's own session keeps running |
| **Super + Tab / Super + 1-5** | Leave the remote workspace. The session stays connected |
| **Super + W** | Close the remote window (same as disconnecting) |

**The first time** you open a Windows or Mac computer, a small terminal asks for the user name and password
(twice). It checks the login once, then saves the password in your keyring. After that it is one click.
If the check says the login was rejected, nothing is saved. Repeated failures can lock an account, so check first.

## The manager (`Super + Shift + R`)

A keyboard-driven screen, in the spirit of [tmax](https://github.com/theo-kirby/tmax): an fzf list of your computers
with status glyphs (`●` connected, `○` online, `·` offline, `★` starred), a preview pane that shows each computer's
**effective settings** (what you set, and what is just the built-in default), and gum menus to change them.

| Key (normal mode) | Does |
|---|---|
| `j` `k` `g` `G` | Move |
| `Enter` | Connect |
| `d` | **Disconnect** (closes the window; the computer's session keeps running) |
| `a` | **Add** a computer that is not on Tailscale (address, system, name, user, then its password) |
| `e` | Edit: name, user, client, UI scale, Mac fit, Command key, Mac display size, reset |
| `p` | Set or change the password (login is verified once before saving) |
| `t` | Test the saved login (asks first, one attempt) |
| `f` | Star (pin to the top) |
| `h` | **Hide / show** a computer (hidden ones leave the bar and `Super + R`, and stay in the manager, dimmed) |
| `x` | **Remove**: forgets the password and settings (you type `yes`). For a computer you added, it removes the computer itself |
| `M` | Mac display: show the mode, choose a size, restore now |
| `r` | Refresh status |
| `/` or `i` | Filter by typing; `Esc` returns to normal mode |
| `?` `q` | Help, quit |

The cached list appears instantly and live status replaces it a moment later. `remote-manage config` prints every
computer's effective settings in the terminal. It needs `fzf` and `gum`, which ship with Omarchy.

## Computers that are not on Tailscale

Tailscale machines appear by themselves. For anything else (a PC on your local network, a server with a public
address), press `a` in the manager and give it an address, a system and a user. It then behaves like the others, with
two differences: it is marked "added" in the manager, and its online state comes from a quick check that its
remote-access port answers (3389 for Windows, 5900 for macOS, 22 for Linux).
Without Tailscale there is no private tunnel: use these only on networks you trust, and prefer Tailscale for anything
reachable from the internet. Remove one with `x`, or hide a Tailscale machine you never use with `h`.

## Settings

Nothing is required. To name a computer or change how it behaves, edit `~/.config/omarchy/remote-computers.json`.
Entries are matched on `host`, the Tailscale machine name.

```json
[
  { "host": "office-pc", "label": "Office", "user": "alex" },
  { "host": "macbook",   "label": "Mac",    "user": "alex", "mac_size": "1600x900" }
]
```

| Field | Applies to | Meaning |
|---|---|---|
| `manual` | added by hand | `true` for a computer you added (needs `host` as an address and `os`) |
| `os` | added by hand | `windows`, `macos` or `linux` |
| `hidden` | all | `true` hides it from the bar and `Super + R` |
| `label` | all | Name shown in the bar and picker |
| `user` | Windows, Mac | Login name (filled in by the first-time prompt) |
| `client` | all | `freerdp` (Windows default), `vnc` (Mac default), `ssh` (Linux default) |
| `scale` | Windows | UI scale in percent. Default is your monitor's scale (200 on a 2x screen) |
| `fit` | Mac | `auto` (default), `contain`, `cover`, `stretch`. See below |
| `cmd` | Mac | `ctrl` (default: Ctrl+C becomes Command+C), `alt`, `none` |
| `mac_display` | Mac | `"off"` to never change the Mac's display |
| `mac_size` | Mac | Force a display mode such as `"1600x900"` instead of the closest match |

Environment variables for troubleshooting: `REMOTE_DEBUG=1` (verbose FreeRDP log), `REMOTE_FREERDP_ARGS="..."`
(extra FreeRDP flags). Logs are in `$XDG_RUNTIME_DIR/remote-desktop-<host>.log`.

## How it works

```
Tailscale ──► remote-desktop-status ──► bar chips + Super+R picker   (Omarchy shell plugins, QML)
                                  │
click ─► remote-desktop ──► workspace "name:<host>" ──► client window
                                  ├─ Windows: sdl-freerdp3  (/size = monitor px, /scale-desktop = monitor scale)
                                  ├─ Mac:     omarchy-vnc   (+ mac-display over SSH)
                                  └─ Linux:   ssh in a terminal
Hyprland: one generic rule for windows of class omarchy-remote-*; gapless workspace per host;
          Super+F -> remote-fullscreen (compositor fullscreen the client is not told about)
```

Details that matter:

- **Sharpness.** FreeRDP's built-in dynamic resize sends the logical size when a window goes fullscreen, which makes
  Windows draw too small and stretched on HiDPI screens. This project instead gives remote windows a tiled, gapless
  layout and `Super + F` uses Hyprland's `fullscreen_state` (compositor fullscreen with the client told it is not
  fullscreen), so the real pixel size is always sent.
- **Windows key.** Both Super keys are remapped to F24 for the remote side, otherwise every Super shortcut would
  also open the Windows Start menu. H.264 is turned off because FreeRDP's VAAPI decoder can stall the window.
- **Mac.** Apple's VNC server cannot resize the Mac's desktop, so `omarchy-vnc` scales the picture to fit. To make
  the Mac *look* like the Windows windows, a small helper (`mac-display`, compiled on the Mac with Apple's own
  command line tools, only CoreGraphics) switches the display to the closest HiDPI mode when you connect and restores
  it when you disconnect. Its changes last for the login session only, so a logout or reboot always reverts them.
  Restore by hand any time: `ssh <mac> '~/.local/bin/mac-display restore'`.
- **Fit modes (Mac).** `auto` stretches only when the window and the Mac's screen differ by less than 4% (not
  noticeable), otherwise it keeps proportions and shows thin bars.

## Keeping Windows computers reachable

Tailscale only helps while a computer is awake. `windows/keep-awake.ps1` makes a Windows PC stay reachable while it
is plugged in: it turns on Tailscale's *Run unattended* (so signing out doesn't drop it) and sets sleep and hibernate
to *never* on AC power, leaving battery settings alone. The original values are saved on the PC. Run it over SSH:

```
ssh <pc> "$(cat windows/keep-awake.ps1)"
```

A sleeping or shut-down PC cannot be woken by Tailscale. Wake-on-LAN needs another always-on device on the same
local network and is unreliable over Wi-Fi; keeping the PC awake while plugged in is simpler.

## Security and privacy

- Passwords are stored with libsecret (GNOME keyring): service `omarchy-remote`, name = host. They are passed to
  FreeRDP and `omarchy-vnc` through standard input, so they never appear in `ps`, shell history or logs.
- It connects to individual machines over Tailscale. It does **not** bridge or route networks, so it never exposes
  a network that one machine happens to be connected to.
- Windows certificates are trusted on first use (`/cert:tofu`). Use Tailscale ACLs to limit who can reach what.
- The Mac helper runs over SSH with your key and only changes the display mode; it never touches files elsewhere.

## Troubleshooting

- **"offline" but the machine works:** Tailscale's flag can lag. The launcher also accepts live traffic or a direct
  path and confirms with a real ping before giving up.
- **"wrong password":** run `remote-desktop-setup <host>` again.
- **Pointer too big on Windows:** at 200% scaling Windows draws a 64 px arrow. Lower Windows' pointer size
  (`HKCU\Control Panel\Cursors\CursorBaseSize`) if you prefer a smaller one.
- **Mac interface too big or small:** set `mac_size` (larger numbers give a smaller interface). Modes are listed by
  `ssh <mac> '~/.local/bin/mac-display list'`.
- **A Windows window closed by itself:** if someone unlocks or uses that computer's own screen, Windows hands the
  session to the physical console and disconnects remote viewers. Click the chip again to take it back.
- **A Windows computer drops off Tailscale when its session is signed out:** turn on Tailscale's *Run unattended*
  setting on that PC so it stays connected without anyone signed in.
- **Windows scale ignored (UI tiny):** a custom display scale (Settings > Display > Scale > Custom) overrides what the
  client requests. Remove it and sign in again so Windows reads the client's scale.
- **Chips look stale after an update:** `omarchy restart shell`.

## Development

```
make            # build omarchy-vnc
make test       # headless login checks against a local test server (right/wrong password, unreachable)
```

`test/testserver.c` is a small libvncserver server that prints the input it receives; `omarchy-vnc --selftest`
sends synthetic mouse, key and clipboard events to it.

## Credits and licenses

**omarchy-remote was developed by JeoCrypto.** It stands on the work of many others:

Built on FreeRDP (Apache-2.0), libvncclient / LibVNCServer (GPL-2.0-or-later), SDL3 (zlib), Tailscale, Hyprland
and Omarchy.

- `src/omarchy-vnc.c`: **GPL-2.0-or-later** (it links libvncclient). See `COPYING.GPL-2.0`.
- Everything else (scripts, plugins, Hyprland rules, `mac/mac-display.c`, tests): **MIT**. See `LICENSE`.

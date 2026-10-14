-- omarchy-remote: developed by JeoCrypto
-- Remote computers as workspaces. ~/.local/bin/remote-desktop opens each computer on its own
-- named workspace; every client window it launches carries the class omarchy-remote-<host>.
-- The remote desktop is a normal tiled Omarchy window, alone on its workspace: no border, no
-- rounded corners, no shadow, full opacity. (The launcher also removes the workspace's gaps, so it
-- fills the area under the bar.) Super+F still gives true fullscreen.
o.window({ class = "^omarchy-remote-.*$" }, {
  tile = true,
  border_size = 0,
  rounding = 0,
  no_shadow = true,
  opacity = "1 1",
  tag = "-default-opacity",
  idle_inhibit = "focus",
})

-- The Super+R picker appears instantly, like Omarchy's own overlays.
hl.layer_rule({ match = { namespace = "^omarchy-remote$" }, no_anim = true, animation = "none" })

-- Gapless workspace for every remote computer opened before (the launcher keeps this list), so the
-- remote desktop fills the area under the bar even after a config reload or a restart.
do
  local f = io.open((os.getenv("HOME") or "") .. "/.local/state/omarchy-remote/hosts", "r")
  if f then
    for host in f:lines() do
      if host:match("^[%w%-_.]+$") then
        hl.workspace_rule({ workspace = "name:" .. host, gaps_in = 0, gaps_out = 0 })
      end
    end
    f:close()
  end
end

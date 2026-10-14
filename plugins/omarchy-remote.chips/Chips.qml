// omarchy-remote: developed by JeoCrypto
import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Remote computers as workspaces. Data comes from ~/.local/bin/remote-desktop-status
// (Tailscale online state + whether the client window exists); a click runs
// ~/.local/bin/remote-desktop <id>, which switches to the computer's workspace.
BarWidget {
  id: root
  moduleName: "omarchy-remote.chips"

  property var computers: []

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)
  readonly property string focusedName: Hyprland.focusedWorkspace ? String(Hyprland.focusedWorkspace.name) : ""

  implicitWidth: computers.length > 0 ? grid.implicitWidth + trailingGap : 0
  implicitHeight: computers.length > 0 ? grid.implicitHeight : 0
  visible: computers.length > 0

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function connect(id) {
    if (!root.bar) return
    root.bar.run("remote-desktop " + Util.shellQuote(id))
    refreshSoon.restart()
  }

  function disconnect(id) {
    if (!root.bar) return
    root.bar.run("remote-desktop --disconnect " + Util.shellQuote(id))
    refreshSoon.restart()
  }

  function osIcon(os) {
    return os === "macos" ? "\uDB80\uDC35" : "\uDB80\uDF72"
  }

  function statusText(c) {
    if (c.open) return c.label + ": connected (right-click to disconnect)"
    if (c.online) return c.label + ": online, click to connect"
    return c.label + ": offline"
  }

  Process {
    id: statusProcess
    running: false
    command: ["remote-desktop-status"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try { root.computers = JSON.parse(String(statusStdout.text || "[]")) } catch (e) { }
    }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Re-check shortly after a click, once the client window has had time to appear.
  Timer {
    id: refreshSoon
    interval: 2500
    repeat: false
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { root.refresh() }
  }

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.computers.length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.computers

      WidgetButton {
        required property var modelData

        readonly property bool focused: root.focusedName === String(modelData.id)

        bar: root.bar
        text: (focused ? "󱓻" : root.osIcon(modelData.os)) + " " + modelData.label
        tooltipText: root.statusText(modelData)
        opacity: focused || modelData.open ? 1 : (modelData.online ? 0.7 : 0.4)
        horizontalMargin: 6
        verticalPadding: 6
        fixedHeight: root.barSize
        onPressed: function(button) {
          if (button === Qt.RightButton) root.disconnect(String(modelData.id))
          else root.connect(String(modelData.id))
        }
      }
    }
  }
}

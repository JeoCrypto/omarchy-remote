// omarchy-remote: developed by JeoCrypto
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Super+R: pick a computer on your Tailscale and open it as a full-screen workspace.
// Data: ~/.local/bin/remote-desktop-status   Action: ~/.local/bin/remote-desktop <id>
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true
  property bool loaded: false
  property bool missingHelpers: false

  // tmux sessions of one computer ("sessions" mode, opened with the right arrow)
  property string mode: "computers"
  property string sessHost: ""
  property string sessLabel: ""
  property var sessions: []
  property bool sessLoading: false
  property string sessError: ""
  property string pendingKill: ""     // "" | a session name | "*" (all): waiting for the second press
  property string notice: ""
  property var computers: []

  // Same surface tokens as the Omarchy menu, so every theme styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Math.max(Style.space(22), Style.font.caption + Style.spacing.md)
  property int rowHeight: Math.max(Style.space(54), Style.font.heading + Style.font.caption + Style.spacing.md * 2)
  property int maxRows: 7
  property int cardWidth: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)
  property int visibleRows: Math.max(1, Math.min(maxRows, displayModel.count))
  property int cardHeight: Math.min(panel.height - Style.gapsOut * 2,
    contentMargin * 2 + headerHeight + contentSpacing + (displayModel.count > 0 ? visibleRows * rowHeight : Style.space(110)) + contentSpacing + footerHeight)

  function osIcon(os) {
    if (os === "macos") return "󰀵"
    if (os === "linux") return "󰌽"
    if (os === "ssh") return "󰆍"
    return "󰍲"
  }

  function statusLabel(c) {
    if (c.open) return "connected"
    return c.online ? "online" : "offline"
  }

  function open(payloadJson) {
    root.opened = true
    root.mode = "computers"
    root.pendingKill = ""
    root.notice = ""
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.refresh()
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy-remote")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    if (root.mode === "sessions") return
    if (!statusProcess.running) statusProcess.running = true
  }

  function say(text) { root.notice = text; noticeTimer.restart() }

  // ---- tmux sessions -------------------------------------------------------------------------------
  function enterSessions(index) {
    if (root.mode !== "computers" || index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind !== "computer") return
    if (row.os === "windows") { root.say("tmux is for Mac, Linux and ssh computers"); return }
    if (!row.online) { root.say(row.label + " is offline"); return }
    root.mode = "sessions"
    root.sessHost = row.cid
    root.sessLabel = row.label
    root.sessions = []
    root.sessError = ""
    root.pendingKill = ""
    root.filterText = ""
    root.selectedIndex = 0
    root.loadSessions()
    root.rebuild()
  }

  function leaveSessions() {
    root.mode = "computers"
    root.pendingKill = ""
    root.filterText = ""
    root.selectedIndex = 0
    root.refresh()
    root.rebuild()
  }

  function loadSessions() {
    root.sessLoading = true
    sessProc.command = ["remote-sessions", "list", root.sessHost]
    sessProc.running = true
  }

  function launchSession(name) {
    var host = root.sessHost
    root.dismiss()
    Quickshell.execDetached(["remote-desktop", "--session", String(name), String(host)])
  }

  function confirmKill(target) {
    if (root.pendingKill === target) {
      root.pendingKill = ""
      killProc.command = target === "*" ? ["remote-sessions", "kill-all", root.sessHost]
                                        : ["remote-sessions", "kill", root.sessHost, target]
      killProc.running = true
    } else {
      root.pendingKill = target
    }
  }

  function killIndex(index, all) {
    if (root.mode !== "sessions") return
    if (all) { if (root.sessions.length > 0) root.confirmKill("*"); return }
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "session") root.confirmKill(row.cid)
    else if (row.kind === "killall") root.confirmKill("*")
  }

  function rebuildSessions() {
    var q = root.filterText.toLowerCase()
    var typed = root.filterText.trim()
    displayModel.clear()
    function add(kind, cid, glyph, label, sub, badge) {
      displayModel.append({ kind: kind, cid: cid, label: label, host: "", os: "", ip: "", online: true, isOpen: false,
                            glyph: glyph, sub: sub, badge: badge })
    }
    if (root.sessLoading) add("info", "", "󰔟", "Asking " + root.sessLabel + "…", "", "")
    else if (root.sessError !== "") add("info", "", "󰀦", root.sessError, "", "")
    var exact = false
    for (var i = 0; i < root.sessions.length; i++) {
      var s = root.sessions[i]
      if (s.name === typed) exact = true
      if (q !== "" && s.name.toLowerCase().indexOf(q) === -1) continue
      add("session", s.name, "󰆍", s.name, s.windows + (s.windows === "1" ? " window" : " windows"),
          root.pendingKill === s.name ? "press ⌃X again" : (parseInt(s.attached) > 0 ? "attached" : "detached"))
    }
    add("new", "", "󰐕", typed !== "" && !exact ? "New session “" + typed + "”" : "New session (type a name)", "", "")
    if (root.sessions.length > 0)
      add("killall", "", "󰆴", "Kill all sessions", "stops tmux on " + root.sessLabel, root.pendingKill === "*" ? "press again" : "")
    if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
    root.cursorActive = true
    Qt.callLater(function() { resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
  }

  function rank(c) { return c.open ? 0 : (c.online ? 1 : 2) }

  function rebuild() {
    if (root.mode === "sessions") { root.rebuildSessions(); return }
    var keepId = ""
    if (displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count)
      keepId = displayModel.get(root.selectedIndex).cid

    var q = root.filterText.toLowerCase()
    var rows = []
    for (var i = 0; i < root.computers.length; i++) {
      var c = root.computers[i]
      var hay = (String(c.label) + " " + String(c.host) + " " + String(c.os)).toLowerCase()
      if (q === "" || hay.indexOf(q) !== -1) rows.push(c)
    }
    rows.sort(function(a, b) {
      var d = root.rank(a) - root.rank(b)
      if (d !== 0) return d
      return String(a.label).toLowerCase().localeCompare(String(b.label).toLowerCase())
    })

    displayModel.clear()
    var keepIndex = -1
    for (var j = 0; j < rows.length; j++) {
      var r = rows[j]
      if (r.id === keepId) keepIndex = j
      displayModel.append({
        kind: "computer", cid: String(r.id), label: String(r.label), host: String(r.host), os: String(r.os),
        ip: String(r.ip || ""), online: r.online === true, isOpen: r.open === true,
        glyph: root.osIcon(String(r.os)),
        sub: String(r.host) + (r.ip ? "  ·  " + String(r.ip) : ""),
        badge: (r.open === true ? "󱓻 " : "") + root.statusLabel(r)
      })
    }

    if (displayModel.count === 0) root.selectedIndex = 0
    else if (keepIndex >= 0) root.selectedIndex = keepIndex
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
    root.cursorActive = displayModel.count > 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function move(delta) {
    if (displayModel.count === 0) return
    root.cursorActive = true
    root.pendingKill = ""
    root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(next) {
    root.pendingKill = ""
    root.filterText = next
    root.selectedIndex = 0
    root.rebuild()
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (root.mode === "sessions") {
      if (row.kind === "session") root.launchSession(row.cid)
      else if (row.kind === "killall") root.confirmKill("*")
      else if (row.kind === "new") {
        var name = root.filterText.trim()
        if (/^[A-Za-z0-9._-]+$/.test(name)) root.launchSession(name)
        else root.say("Type a session name: letters, digits, dot, dash, underscore")
      }
      return
    }
    root.dismiss()
    Quickshell.execDetached(["remote-desktop", String(row.cid)])
  }

  function disconnectIndex(index) {
    if (root.mode !== "computers") return
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.dismiss()
    Quickshell.execDetached(["remote-desktop", "--disconnect", String(row.cid)])
  }

  ListModel { id: displayModel }

  Process {
    id: statusProcess
    running: false
    command: ["bash", "-c", "command -v remote-desktop-status >/dev/null || exit 127; exec remote-desktop-status"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.missingHelpers = exitCode !== 0
      if (exitCode !== 0) { root.computers = []; root.loaded = true; if (root.opened) root.rebuild(); return }
      try { root.computers = JSON.parse(String(statusStdout.text || "[]")) } catch (e) { }
      root.loaded = true
      if (root.opened) root.rebuild()
    }
  }

  Process {
    id: sessProc
    running: false
    stdout: StdioCollector { id: sessStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.sessLoading = false
      if (exitCode === 0) {
        var out = []
        var lines = String(sessStdout.text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length >= 3 && f[0] !== "") out.push({ name: f[0], windows: f[1], attached: f[2] })
        }
        root.sessions = out
        root.sessError = ""
      } else {
        root.sessions = []
        root.sessError = exitCode === 3 ? "Can't reach " + root.sessLabel + " over ssh (needs key login)" : "Could not list the sessions"
      }
      if (root.opened && root.mode === "sessions") root.rebuild()
    }
  }

  Process {
    id: killProc
    running: false
    onExited: function(exitCode) {
      if (root.mode === "sessions") { root.loadSessions(); root.rebuild() }
    }
  }

  Timer { id: noticeTimer; interval: 2500; repeat: false; onTriggered: root.notice = "" }

  // Keep the list live while it's open (a computer coming online, a session starting).
  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-remote"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.pendingKill !== "") root.pendingKill = ""
            else if (root.filterText) root.setFilter("")
            else if (root.mode === "sessions") root.leaveSessions()
            else root.dismiss()
            if (root.mode === "sessions") root.rebuild()
            event.accepted = true
          } else if (event.key === Qt.Key_Right && root.mode === "computers" && root.filterText === "") {
            root.enterSessions(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_T && event.modifiers === Qt.ControlModifier && root.mode === "computers") {
            root.enterSessions(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Left && root.mode === "sessions" && root.filterText === "") {
            root.leaveSessions()
            event.accepted = true
          } else if (event.key === Qt.Key_X && (event.modifiers & Qt.ControlModifier) && root.mode === "sessions") {
            root.killIndex(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0)
            root.rebuild()
            event.accepted = true
          } else if (event.key === Qt.Key_D && event.modifiers === Qt.ControlModifier) {
            root.disconnectIndex(root.selectedIndex)
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab
                     || (event.key === Qt.Key_P && event.modifiers === Qt.ControlModifier)
                     || (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier)) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab
                     || (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier)
                     || (event.key === Qt.Key_J && event.modifiers === Qt.ControlModifier)) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                     && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || (root.mode === "sessions" ? "tmux on " + root.sessLabel + "…" : "Connect to…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: 0
            boundsBehavior: Flickable.StopAtBounds
            visible: displayModel.count > 0

            delegate: Rectangle {
              id: row
              required property int index
              required property string cid
              required property string label
              required property string host
              required property string os
              required property string ip
              required property bool online
              required property bool isOpen
              required property string kind
              required property string glyph
              required property string sub
              required property string badge

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"
              opacity: isOpen || online ? 1 : 0.5

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(12)

                Text {
                  textFormat: Text.PlainText
                  text: row.glyph
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  Layout.alignment: Qt.AlignVCenter
                }

                Column {
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.label
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.sub
                    visible: row.sub !== ""
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: row.badge
                  color: row.isOpen ? root.selectedText : root.foreground
                  opacity: row.isOpen ? 1 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.alignment: Qt.AlignVCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onClicked: {
                  root.selectedIndex = row.index
                  root.activateIndex(row.index)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰊻"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: !root.loaded ? "Looking for computers…"
                    : root.missingHelpers ? "Setup needed. In a terminal run:\n~/.config/omarchy/plugins/omarchy-remote/setup.sh"
                    : (root.filterText ? "No matches for “" + root.filterText + "”" : "No computers on your Tailscale")
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          height: root.footerHeight
          text: root.notice !== "" ? root.notice
                : root.mode === "sessions" ? (root.pendingKill !== "" ? "⌃X again to confirm · esc cancels" : "↵ open     ⌃X kill     ⌃⇧X kill all     ← back")
                : "↵ connect     → tmux     ⌃D disconnect     esc close"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }
}

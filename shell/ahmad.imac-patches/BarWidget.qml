import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Which iMac patches are on, in the bar. The list, the names and the toggling
// all come from imac-patcher itself (`--list`, `--toggle`), so this widget
// holds no knowledge of its own about what a patch is or how to apply one:
// add a module to the patcher and it appears here.
BarWidget {
  id: root
  moduleName: "ahmad.imac-patches"

  property var rows: []
  property bool popupOpen: false
  property bool loaded: false

  readonly property int offCount: {
    var n = 0
    for (var i = 0; i < rows.length; i++)
      if (rows[i].state === "not-applied") n++
    return n
  }

  function close() { popupOpen = false }
  function refresh() { if (!listProc.running) listProc.running = true }

  function parseList(raw) {
    var out = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      // id, tier, state, title -- anything the patcher says is not applicable
      // to this machine is left out rather than shown as a dead row.
      if (p.length < 4 || p[2] === "n/a") continue
      out.push({ id: p[0], tier: p[1], state: p[2], label: p[3] })
    }
    rows = out
    loaded = true
  }

  // Toggling asks for a terminal on purpose: applying a patch can want sudo,
  // can rebuild a kernel module, and always has something to say. The patcher
  // is the only thing that decides what a toggle means.
  function toggle(id) {
    popupOpen = false
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation imac-patcher --toggle " + id)
    refreshLater.restart()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Also reachable without the mouse: `omarchy-shell ipc call ahmad.imac-patches
  // toggle`, which is what a keybind would use.
  IpcHandler {
    target: "ahmad.imac-patches"
    function toggle(): void { root.refresh(); root.popupOpen = !root.popupOpen }
    function open(): void   { root.refresh(); root.popupOpen = true }
    function close(): void  { root.popupOpen = false }
    function refresh(): void { root.refresh() }
  }

  Process {
    id: listProc
    command: ["imac-patcher", "--list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseList(text)
    }
  }

  // A toggle runs in its own terminal, so there is no exit code to wait on;
  // re-read a little later, and again on the next open.
  Timer { id: refreshLater; interval: 8000; repeat: false; onTriggered: root.refresh() }
  Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf179"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    onPressed: {
      root.refresh()
      root.popupOpen = !root.popupOpen
    }
    tooltipText: root.loaded
      ? (root.offCount === 0 ? "iMac patches — all on" : "iMac patches — " + root.offCount + " off")
      : "iMac patches"
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(2)

      PanelSectionHeader {
        text: "iMac patches"
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      Repeater {
        model: root.rows
        delegate: Rectangle {
          id: rowItem
          required property var modelData
          readonly property bool on: modelData.state === "applied"
          width: column.width
          height: Style.space(30)
          radius: Style.spacing.labelGap
          color: rowHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

          HoverHandler { id: rowHover }
          TapHandler { onTapped: root.toggle(rowItem.modelData.id) }

          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: rowItem.on ? "✓" : "·"
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: rowItem.on ? 1.0 : 0.45
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              width: Style.space(14)
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: rowItem.modelData.label
              elide: Text.ElideRight
              width: parent.width - Style.space(22) - (tierTag.visible ? tierTag.width + Style.space(8) : 0)
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: rowItem.on ? 1.0 : 0.6
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: tierTag
              textFormat: Text.PlainText
              // "app" marks a patch to someone else's code, which switches
              // itself off when that app moves on. Worth saying in the list.
              visible: rowItem.modelData.tier === "app"
              text: "app"
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.4
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Rectangle {
        width: column.width
        height: Style.space(28)
        radius: Style.spacing.labelGap
        color: allHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
        HoverHandler { id: allHover }
        TapHandler {
          onTapped: {
            root.popupOpen = false
            if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation imac-patcher")
          }
        }
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(30)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Open the patcher"
          color: root.bar ? root.bar.foreground : Color.foreground
          opacity: 0.75
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}

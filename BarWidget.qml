import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar slot for TickTick. The panel owns the cache, the sync timer, and the
// CLI; this reads the already-shaped label off it so the count stays live
// whether or not the popup has ever been opened.
BarWidget {
  id: root
  moduleName: "io.github.sotoaugusto.ticktick"

  // nf-fa-tasks. A checklist reads as "things to do" at bar size in a way
  // a check mark does not — a check mark reads as "done".
  //
  // Written as an escape, not as the literal glyph: a raw private-use-area
  // character does not survive every editor and tool that touches this file,
  // and when it is silently dropped the widget renders a bare number.
  readonly property string icon: ""

  readonly property string panelLabel: panelLoader.item ? panelLoader.item.label : ""
  readonly property int overdueCount: panelLoader.item ? panelLoader.item.overdueCount : 0
  readonly property bool hasWork: panelLoader.item ? panelLoader.item.hasWork : false
  readonly property bool signedIn: panelLoader.item ? panelLoader.item.signedIn : false

  // A live countdown outranks the task count: while a block is running,
  // the remaining time is the only thing on the bar worth the space.
  readonly property string pomoClock: panelLoader.item ? panelLoader.item.pomoClock : ""
  readonly property bool pomoRunning: panelLoader.item ? panelLoader.item.pomoRunning === true : false
  readonly property bool pomoPaused: panelLoader.item ? panelLoader.item.pomoPaused === true : false
  readonly property bool pomoActive: pomoRunning || pomoPaused

  // An unconnected plugin gets its own glyph rather than a dimmed checklist:
  // a faint "0 tasks" reads as "nothing to do", which is the opposite of
  // "needs setup". A plug says which one it is at a glance.
  readonly property string setupIcon: ""

  readonly property string activeIcon: !signedIn
    ? setupIcon
    : (pomoActive ? "" : icon)
  readonly property string activeLabel: !signedIn
    ? "setup"
    : (pomoActive ? pomoClock : panelLabel)

  readonly property string displayText: activeLabel === "" ? activeIcon : activeIcon + "  " + activeLabel
  readonly property var verticalLines: activeLabel === "" ? [activeIcon] : [activeIcon, activeLabel]

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity, the same way the first-party panel widgets do.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // An IPC target routes to exactly one handler, but this widget is live once
  // per monitor, so the instance that claimed the target is rarely the one you
  // are looking at. The bar already resolves this for `shell.summon` by asking
  // Hyprland which output is focused; these calls borrow the same resolution
  // instead of acting locally and opening a panel on the other screen.
  function focusedInstance() {
    if (root.bar && typeof root.bar.findPanelWidget === "function") {
      var item = root.bar.findPanelWidget(root.moduleName)
      if (item) return item
    }
    return root
  }

  IpcHandler {
    target: "io.github.sotoaugusto.ticktick"

    // Refresh is not a place, so it goes to every instance.
    function sync(): void { root.broadcast("refresh") }

    function open(): void { root.focusedInstance().open() }
    function close(): void { root.focusedInstance().close() }
    function show(): void { root.focusedInstance().open() }
    function hide(): void { root.focusedInstance().close() }
    function toggle(): void { root.focusedInstance().togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1

    // Late work is the one state worth spending the bar's urgent color on.
    active: root.pomoActive ? root.pomoRunning : root.overdueCount > 0
    // A disconnected plugin should look inert rather than like zero work.
    dimmed: !root.signedIn

    tooltipText: root.signedIn
      ? (root.hasWork ? "TickTick — click to review" : "TickTick — all clear")
      : "TickTick — click to connect"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) { if (root.bar) root.bar.run("xdg-open https://ticktick.com/webapp") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 2 ? button.fontSize * 0.85 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}

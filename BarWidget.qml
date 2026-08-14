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

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("io.github.sotoaugusto.ticktick")
    : null

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

  // In "Next" mode the label is a task title, which is as long as someone
  // felt like typing. The bar scrolls it rather than cutting it off, the same
  // way the first-party media widget scrolls a track name — and, like that
  // widget, only in the bar. The panel's rows still elide, because seven
  // scrolling lines cannot be scanned.
  readonly property string barLabelMode: setting("barLabel", "Count")
  readonly property string nextTitle: panelLoader.item ? panelLoader.item.nextTitle : ""
  readonly property bool marquee: !vertical && !pomoActive && signedIn
    && barLabelMode === "Next" && nextTitle !== ""
  readonly property real marqueeWidth: Style.space(150)

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

    // The focus clock lives in the service, so these are not per-monitor and
    // need no routing. Bindable: `omarchy-shell <id> focus` starts or pauses
    // a block without opening anything.
    function focus(): void { if (root.service) root.service.togglePomo() }
    function focusStop(): void { if (root.service) root.service.stopPomo() }

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
    text: (root.vertical || root.marquee) ? "" : root.displayText
    fixedWidth: root.marquee ? root.marqueeWidth + Style.space(30) : -1
    labelVisible: !root.vertical
    // The marquee draws its own children, so the slot has content even though
    // the button's own text is empty. Without this the bar treats it as blank
    // and the widget disappears.
    hasVisualContent: root.marquee
      ? true
      : (root.vertical ? root.verticalLines.length > 0 : text !== "")
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

    // Scrolling label. Held to one clip so the glyph stays put and only the
    // title moves.
    Row {
      visible: root.marquee
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.activeIcon
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }

      Item {
        id: scrollClip
        width: Math.min(root.marqueeWidth, marqueeText.implicitWidth)
        height: button.height
        clip: true
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: marqueeText
          text: root.nextTitle
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          anchors.verticalCenter: parent.verticalCenter

          readonly property bool needsScroll: implicitWidth > scrollClip.width

          // Scroll to the end, wait, come back — the same motion the panel
          // rows use. A continuous wrap, as the media widget does it, sends
          // the title off one edge and back in the other, which leaves the
          // bar slot looking empty for part of every loop. A track name can
          // afford that; a task you are being reminded of cannot.
          onNeedsScrollChanged: if (!needsScroll) x = 0

          SequentialAnimation on x {
            running: marqueeText.needsScroll && !root.opened
            loops: Animation.Infinite

            PauseAnimation { duration: 2000 }
            NumberAnimation {
              from: 0
              to: Math.min(0, scrollClip.width - marqueeText.implicitWidth)
              // Constant reading speed: a longer title takes longer rather
              // than moving faster.
              duration: Math.max(900, (marqueeText.implicitWidth - scrollClip.width) * 28)
              easing.type: Easing.Linear
            }
            PauseAnimation { duration: 1600 }
            NumberAnimation { to: 0; duration: 400; easing.type: Easing.OutCubic }
          }
        }
      }
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

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// TickTick popup: what is due, what habits are still open, and the two
// actions that matter on a bar — tick a task off, check a habit in.
//
// The panel never talks to TickTick itself. `bin/omarchy-ticktick` owns the
// session token and every request; this reads the JSON cache that CLI
// writes and shells back out for writes. That keeps a long-lived credential
// out of the shell process and makes every mutation a single auditable
// command.
Panel {
  id: root
  moduleName: "io.github.sotoaugusto.ticktick"
  ipcTarget: "io.github.sotoaugusto.ticktick"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string cli: pluginDir + "bin/omarchy-ticktick"

  // ---- the shared service ------------------------------------------------
  //
  // A bar exists per monitor, so this panel exists per monitor too. The cache,
  // the sync timer, the write queue, the undo window, and the focus clock are
  // all single-instance concerns and live in Service.qml; this reads them.
  // Without that split, two screens meant two focus clocks each logging the
  // same block.
  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("io.github.sotoaugusto.ticktick")
    : null

  // The service has no settings of its own; every panel carries the same
  // inline entry, so whichever loads first hands them over.
  onSvcChanged: pushSettings()
  onSettingsChanged: pushSettings()
  function pushSettings() {
    if (svc && "settings" in svc) svc.settings = root.settings
  }

  // ---- cache (read through the service) ----------------------------------

  readonly property var cache: svc ? svc.cache : Model.parseCache("")
  readonly property date nowDate: svc ? svc.nowDate : new Date()

  readonly property bool signedIn: cache.syncedAt > 0 && !cache.authRequired
  readonly property string cacheError: cache.error ? String(cache.error) : ""
  // Writes made while TickTick was unreachable, waiting on the next sync.
  readonly property int queuedCount: cache.queued || 0

  readonly property int staleMinutes: Model.staleMinutes(cache.syncedAt, nowDate.getTime())

  readonly property int todayStamp: Model.dateStamp(nowDate)

  readonly property bool showTasks: setting("showTasks", true) !== false
  readonly property bool showHabits: setting("showHabits", true) !== false
  readonly property bool showPomo: setting("showPomo", true) !== false
  // The configured horizon is the default the panel opens at; `viewHorizon`
  // is what it is currently showing. Widening is a look, not a preference
  // change, so it resets when the panel closes.
  readonly property string horizon: setting("horizon", "Today")
  property string viewHorizon: horizon
  onHorizonChanged: viewHorizon = horizon

  function cycleView(delta) {
    viewHorizon = Model.cycleHorizon(viewHorizon, delta)
  }

  // Naming the destination beats naming the direction: the control wraps, so
  // "further ahead" is wrong exactly when you are at the widest view.
  readonly property string nextView: Model.cycleHorizon(viewHorizon, 1)
  readonly property string viewSwitchHint: (nextView === "Today" ? "Back to " : "Show ") + nextView
  readonly property bool includeOverdue: setting("includeOverdue", true) !== false
  readonly property int maxTasks: Math.max(3, parseInt(setting("maxTasks", 12), 10) || 12)

  readonly property var pendingIds: svc ? svc.pendingIds : ({})
  readonly property var pendingHabitIds: svc ? svc.pendingHabitIds : ({})
  readonly property var pendingAdds: svc ? svc.pendingAdds : []
  readonly property var pendingAction: svc ? svc.pendingAction : null
  readonly property int undoLeft: svc ? svc.undoLeft : 0
  readonly property int undoSeconds: svc ? svc.undoSeconds : 6
  readonly property string actionError: svc ? svc.actionError : ""
  readonly property bool connecting: svc ? svc.connecting : false
  readonly property int refreshIntervalSec: svc ? svc.refreshIntervalSec : 300

  readonly property var pomoStats: svc ? svc.pomoStats : ({})
  readonly property var pomoPrefs: svc ? svc.pomoPrefs : ({})
  readonly property string pomoPhase: svc ? svc.pomoPhase : "idle"
  readonly property bool pomoRunning: svc ? svc.pomoRunning === true : false
  readonly property bool pomoPaused: svc ? svc.pomoPaused === true : false
  readonly property string pomoClock: svc ? svc.pomoClock : ""

  readonly property bool syncing: svc ? svc.syncing === true : false

  function refresh(force) { if (svc) svc.refresh(force) }
  function runAction(args) { if (svc) svc.runAction(args) }
  function completeTask(task) { if (svc) svc.completeTask(task) }
  function checkInHabit(habit) { if (svc) svc.checkInHabit(habit) }
  function cancelPending() { if (svc) svc.cancelPending() }
  function flushPending() { if (svc) svc.flushPending() }
  function startPomo(phase) { if (svc) svc.startPomo(phase) }
  function pausePomo() { if (svc) svc.pausePomo() }
  function resumePomo() { if (svc) svc.resumePomo() }
  function stopPomo() { if (svc) svc.stopPomo() }
  function togglePomo() { if (svc) svc.togglePomo() }

  function connectWithToken() {
    if (!svc) return
    svc.connectWithToken(tokenPaste.text)
    tokenPaste.text = ""
  }

  function submitQuickAdd() {
    if (!svc) return
    var text = String(quickAdd.text || "").trim()
    if (text === "") return
    quickAdd.text = ""
    var parsed = svc.submitQuickAdd(text)
    // Adding something due later must not file it out of sight, so the view
    // widens to wherever the task landed. That stays here: the range being
    // shown is this screen's business, not the service's.
    if (parsed)
      viewHorizon = Model.widerHorizon(viewHorizon, Model.horizonForDue(parsed.due, nowDate))
  }


  readonly property var allDueTasks: showTasks
    ? Model.dueTasks(cache.tasks, { now: nowDate, horizon: viewHorizon, includeOverdue: includeOverdue })
    : []
  readonly property var visibleTasks: filterPending(allDueTasks)
  readonly property var listedTasks: visibleTasks.slice(0, maxTasks)

  readonly property var displayTasks: pendingAdds.concat(listedTasks)
  readonly property int hiddenTaskCount: Math.max(0, visibleTasks.length - listedTasks.length)
  readonly property int overdueCount: Model.overdueCount(visibleTasks, nowDate)

  // Tag colours are the only colours TickTick actually stores for a task,
  // so they are the only ones taken literally. Due state is painted from the
  // theme instead — a hardcoded red would fight every Omarchy theme.
  readonly property var tagsById: Model.tagIndex(cache.tags)

  // ---- keyboard cursor. Same idiom as the first-party panels: the cursor
  //      only becomes visible once a key is pressed, and mouse hover keeps
  //      it in sync so the two input modes never disagree about "current".
  property bool cursorActive: false
  property int cursor: -1
  property bool helpVisible: false

  readonly property var navRows: {
    var rows = []
    if (showTasks) {
      for (var i = 0; i < displayTasks.length; i++) rows.push({ section: "task", index: i })
    }
    if (showHabits) {
      for (var j = 0; j < habits.length; j++) rows.push({ section: "habit", index: j })
    }
    return rows
  }

  function moveCursor(delta) {
    cursorActive = true
    var count = navRows.length
    if (count === 0) { cursor = -1; return }
    if (cursor < 0) cursor = delta > 0 ? 0 : count - 1
    else cursor = Math.max(0, Math.min(count - 1, cursor + delta))
  }

  function syncCursorTo(section, index) {
    for (var i = 0; i < navRows.length; i++) {
      if (navRows[i].section === section && navRows[i].index === index) { cursor = i; return }
    }
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= navRows.length) return
    var row = navRows[cursor]
    // completeTask ignores an id-less ghost, so a pending row is inert
    // rather than silently completing the wrong task.
    if (row.section === "task") completeTask(displayTasks[row.index])
    else checkInHabit(habits[row.index])
  }

  function isCursorOn(section, index) {
    if (!cursorActive || cursor < 0 || cursor >= navRows.length) return false
    var row = navRows[cursor]
    return row.section === section && row.index === index
  }

  // The list shrinks as things get completed; a cursor left past the end
  // would silently act on the wrong row next time.
  onNavRowsChanged: if (cursor >= navRows.length) cursor = navRows.length - 1

  readonly property var habits: showHabits ? (cache.habits || []) : []
  readonly property int habitsRemaining: Model.habitsRemaining(habits, cache.checkins, todayStamp)

  // What the bar reads off this panel.
  readonly property string label: Model.barLabel(setting("barLabel", "Count"), visibleTasks, habitsRemaining, nowDate)
  readonly property bool hasWork: visibleTasks.length > 0 || habitsRemaining > 0

  function filterPending(tasks) {
    var result = []
    for (var i = 0; i < tasks.length; i++) {
      if (!pendingIds[tasks[i].id]) result.push(tasks[i])
    }
    return result
  }

  // ---- lifecycle --------------------------------------------------------

  function open() {
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    root.refresh()
  }

  function close() {
    // Closing is not a cancel. Anything still held is sent, so a click
    // followed by a close does what the click said it would.
    flushPending()
    viewHorizon = horizon
    quickAdd.text = ""
    quickAdd.focus = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // `force` is an explicit user action — opening the panel, the sync button,
  // `r`. Timer ticks are not: they pass a max age so the second monitor's
  // instance skips work the first one just did.
  // Syncing is the service's job; this only asks.

  // ---- surface ----------------------------------------------------------

  readonly property color fg: Color.popups.text
  readonly property color muted: Qt.darker(fg, 1.5)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: quickAdd.activeFocus
      // Escape backs out one layer at a time — help, then a held action,
      // then the panel itself.
      onCloseRequested: {
        if (root.helpVisible) root.helpVisible = false
        else if (root.pendingAction) root.cancelPending()
        else root.close()
      }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
      }
      onActivateRequested: root.activateCursor()
      // Destructive actions answer to Delete in the first-party panels, so
      // discarding a focus block does too.
      onDeleteRequested: root.stopPomo()
      onReturnRequested: root.activateCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "?") root.helpVisible = !root.helpVisible
        else if (text === "r") root.refresh()
        else if (text === "a") quickAdd.forceActiveFocus()
        else if (text === "u") root.cancelPending()
        else if (text === "p") {
          if (root.pomoRunning) root.pausePomo()
          else if (root.pomoPaused) root.resumePomo()
          else root.startPomo("focus")
        }
        else if (text === "d") root.stopPomo()
        else if (text === "v") root.cycleView(1)
        else if (text === "V") root.cycleView(-1)
        else if (text === "g") root.moveCursor(-root.navRows.length)
        else if (text === "G") root.moveCursor(root.navRows.length)
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(8)

          // ---- header
          Item {
            width: parent.width
            height: Math.max(headerText.implicitHeight, syncButton.height)

            Column {
              id: headerText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              // The title is the view switch. It already named the range, so
              // making it the control keeps one label instead of adding a
              // second one that says the same thing.
              // The hit area wraps the Row rather than sitting inside it:
              // a filling MouseArea is a horizontal anchor, and Row refuses
              // to lay out at all when one of its children uses those.
              Item {
                implicitWidth: viewRow.implicitWidth
                implicitHeight: viewRow.implicitHeight
                width: implicitWidth
                height: implicitHeight

                Row {
                  id: viewRow
                  spacing: Style.space(5)

                  Text {
                    id: viewLabel
                    text: root.visibleTasks.length === 0 && root.habitsRemaining === 0
                      ? "All clear"
                      : root.viewHorizon
                    color: viewSwitch.containsMouse ? Color.accent : root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  // Position dots, not a chevron. A chevron promises a
                  // dropdown; this cycles. The dots also say how many ranges
                  // there are and which one is showing, which the chevron
                  // never did.
                  Row {
                    anchors.verticalCenter: viewLabel.verticalCenter
                    spacing: Style.space(3)

                    Repeater {
                      model: Model.horizons()

                      Text {
                        required property int index
                        readonly property bool current: index === Model.horizonIndex(root.viewHorizon)

                        text: current ? "●" : "○"
                        color: current
                          ? (viewSwitch.containsMouse ? Color.accent : root.fg)
                          : root.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                MouseArea {
                  id: viewSwitch
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.cycleView(1)

                  PanelToolTip {
                    text: root.viewSwitchHint + "  (v)"
                    visible: viewSwitch.containsMouse
                  }
                }
              }

              Text {
                text: root.headerSubtitle()
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Offline work should be visible without opening anything. It
            // sits next to the sync button because that is what clears it.
            Text {
              anchors.right: helpButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.queuedCount > 0
              text: " " + root.queuedCount
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption

              PanelToolTip {
                text: root.queuedCount + " change(s) waiting for TickTick"
                visible: queuedHover.containsMouse
              }

              MouseArea {
                id: queuedHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refresh()
              }
            }

            PanelActionButton {
              id: helpButton
              anchors.right: syncButton.left
              anchors.rightMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "Keyboard shortcuts  (?)"
              foreground: root.helpVisible ? Color.accent : root.muted
              onClicked: root.helpVisible = !root.helpVisible
            }

            PanelActionButton {
              id: syncButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.syncing ? "" : ""
              tooltipText: root.syncing ? "Syncing…" : "Sync now"
              foreground: root.fg
              onClicked: root.refresh()
            }
          }

          // ---- keyboard help. Reachable two ways on purpose: `?` for the
          //      keyboard, the header button for the mouse. A shortcut list
          //      only findable by shortcut helps whoever needs it least.
          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: root.helpVisible

            PanelSeparator { width: parent.width; foreground: root.fg }

            PanelSectionHeader { text: "KEYS"; foreground: root.fg }

            Repeater {
              model: [
                { key: "\u2191 \u2193", what: "move between tasks and habits" },
                { key: "enter", what: "complete task / check habit in" },
                { key: "u", what: "undo the held action" },
                { key: "a", what: "add a task" },
                { key: "#tag", what: "tag it — # is TickTick's own" },
                { key: "!1 !2 !3", what: "priority: high, medium, low" },
                { key: "tomorrow", what: "a trailing date word sets the due date" },
                { key: "r", what: "sync now" },
                { key: "p", what: "start or pause focus" },
                { key: "d / del", what: "discard the focus block" },
                { key: "g / G", what: "first / last row" },
                { key: "v", what: "cycle range: today \u2192 tomorrow \u2192 7 days \u21ba" },
                { key: "tab", what: "next bar panel" },
                { key: "?", what: "show or hide this list" },
                { key: "esc", what: "back out, then close" }
              ]

              Row {
                required property var modelData
                width: content.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(52)
                  horizontalAlignment: Text.AlignRight
                  text: modelData.key
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  text: modelData.what
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- undo window
          Rectangle {
            width: parent.width
            height: root.pendingAction ? Style.space(28) : 0
            visible: root.pendingAction !== null
            radius: Style.space(4)
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(40)
                elide: Text.ElideRight
                text: Model.undoLabel(root.pendingAction, root.undoLeft)
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cancelPending()
            }
          }

          // ---- not signed in
          // ---- setup. This is the only onboarding surface the plugin gets:
          //      `omarchy plugin add` never runs plugin code or install
          //      hooks, so there is no post-install script to lean on.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.signedIn

            PanelSeparator { width: parent.width; foreground: root.fg }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.cache.authRequired
                ? "TickTick ended this session. Paste a fresh token to reconnect."
                : "Connect your TickTick account. This takes one paste."
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "1. Open ticktick.com and sign in\n"
                + "2. F12 → Application → Cookies → https://ticktick.com\n"
                + "3. Copy the value of the cookie named  t"
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              lineHeight: 1.35
            }

            TextField {
              id: tokenPaste
              width: parent.width
              // The token is equivalent to a password, so it is masked and
              // never echoed back into the panel.
              password: true
              placeholderText: "Paste the t cookie value…"
              foreground: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              enabled: !root.connecting
              onAccepted: root.connectWithToken()
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: root.connecting ? "Connecting…" : "Connect"
                enabled: !root.connecting && String(tokenPaste.text || "").trim() !== ""
                onClicked: root.connectWithToken()
              }

              Button {
                text: "Open TickTick"
                onClicked: if (root.bar) root.bar.run("xdg-open https://ticktick.com/webapp")
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: !root.cache.authRequired
              text: " The token stays on this machine, in a 0600 file. Nothing reads your browser."
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ---- quick add
          TextField {
            id: quickAdd
            width: parent.width
            visible: root.signedIn && root.showTasks
            placeholderText: "Add a task…  #tag  !1  tomorrow"
            foreground: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            onAccepted: root.submitQuickAdd()
            Keys.onEscapePressed: {
              text = ""
              keyCatcher.forceActiveFocus()
            }
          }

          // ---- tasks
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.signedIn && root.showTasks

            PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: sectionLabel_tasks.implicitHeight

              PanelSectionHeader {
                id: sectionLabel_tasks
                anchors.left: parent.left
                text: "TASKS"
                foreground: root.fg
              }

              PanelSectionHeader {
                anchors.right: parent.right
                anchors.baseline: sectionLabel_tasks.baseline
                text: root.overdueCount > 0
                  ? root.overdueCount + " LATE"
                  : String(root.visibleTasks.length)
                foreground: root.overdueCount > 0 ? Color.accent : root.muted
              }
            }

            Text {
              width: parent.width
              visible: root.displayTasks.length === 0
              text: "Nothing due."
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.displayTasks

              Rectangle {
                id: taskRow
                required property var modelData
                required property int index
                readonly property bool selected: root.isCursorOn("task", index)
                readonly property bool pending: modelData.ghost === true
                readonly property bool late: !pending && Model.isOverdue(modelData, root.nowDate)
                readonly property string tier: Model.dueTier(modelData, root.nowDate)
                readonly property string tagHex: Model.tagColor(modelData, root.tagsById)
                readonly property string tagName: Model.tagLabel(modelData, root.tagsById)

                width: content.width
                height: Style.space(26)
                radius: Style.space(4)
                color: (taskHover.containsMouse || taskRow.selected)
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                  : "transparent"
                // Hover tints, the keyboard cursor outlines. Two different
                // states deserve two different marks, not two strengths of
                // the same one.
                border.width: taskRow.selected ? 1 : 0
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)

                // Row-wide hover for the highlight only. It deliberately
                // accepts no buttons: completion is irreversible from here,
                // so the row must not be a 300px-wide destructive target.
                MouseArea {
                  id: taskHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                  // Hover takes the cursor so keyboard and mouse never
                  // disagree about which row is current.
                  onContainsMouseChanged: if (containsMouse) {
                    root.cursorActive = false
                    root.syncCursorTo("task", taskRow.index)
                  }
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  // The only thing that completes a task. Small and
                  // deliberate, because there is no undo in the panel.
                  Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    height: Style.space(18)

                    Text {
                      anchors.centerIn: parent
                      opacity: taskRow.pending ? 0.45 : 1
                      text: circleHover.containsMouse ? "" : ""
                      color: taskRow.late ? Color.accent : root.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                      id: circleHover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.completeTask(taskRow.modelData)
                    }
                  }

                  // The task's own tag colour, straight from TickTick.
                  //
                  // The column is reserved even when empty. A Row gives an
                  // invisible child no width, so hiding the dot used to slide
                  // every untagged title left and break the one vertical line
                  // the eye follows down the list.
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: taskRow.tagHex === "" ? 0 : 1
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: width / 2
                    color: taskRow.tagHex === "" ? "transparent" : taskRow.tagHex

                    PanelToolTip {
                      text: taskRow.tagName
                      visible: tagHover.containsMouse && taskRow.tagName !== ""
                    }

                    MouseArea {
                      id: tagHover
                      anchors.fill: parent
                      hoverEnabled: true
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(30)
                      - (taskRow.tagHex !== "" ? Style.space(14) : 0)
                      - dueLabel.implicitWidth
                    elide: Text.ElideRight
                    text: String(taskRow.modelData.title || "")
                    // Three tiers, not two: overdue shouts, today is normal
                    // weight, anything further out recedes.
                    color: taskRow.tier === "upcoming" ? root.muted : root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: Model.priorityRank(taskRow.modelData) === "high"
                  }

                  Text {
                    id: dueLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: taskRow.pending ? "adding…" : Model.dueLabel(taskRow.modelData, root.nowDate)
                    color: taskRow.tier === "overdue"
                      ? Color.accent
                      : (taskRow.tier === "today" ? root.fg : root.muted)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.hiddenTaskCount > 0
              text: "+" + root.hiddenTaskCount + " more"
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ---- habits
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.signedIn && root.showHabits && root.habits.length > 0

            PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: sectionLabel_habits.implicitHeight

              PanelSectionHeader {
                id: sectionLabel_habits
                anchors.left: parent.left
                text: "HABITS"
                foreground: root.fg
              }

              PanelSectionHeader {
                anchors.right: parent.right
                anchors.baseline: sectionLabel_habits.baseline
                text: root.habitsRemaining > 0 ? root.habitsRemaining + " LEFT" : "DONE"
                foreground: root.muted
              }
            }

            Repeater {
              model: root.habits

              Rectangle {
                id: habitRow
                required property var modelData
                required property int index
                readonly property bool selected: root.isCursorOn("habit", index)
                readonly property var rawProgress: Model.habitProgress(modelData, root.cache.checkins, root.todayStamp)
                // A held check-in shows as done immediately; undo puts it back.
                readonly property var progress: root.pendingHabitIds[String(modelData.id)]
                  ? { value: rawProgress.goal, goal: rawProgress.goal, ratio: 1, done: true, quantified: rawProgress.quantified }
                  : rawProgress
                readonly property int streak: Model.habitStreak(root.cache.checkins, modelData.id, root.todayStamp)

                width: content.width
                height: Style.space(26)
                radius: Style.space(4)
                color: (habitHover.containsMouse || habitRow.selected)
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                  : "transparent"
                border.width: habitRow.selected ? 1 : 0
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)

                // Parity with tasks: the row highlights, the circle acts.
                // Clicking a habit's name used to check it in, which is the
                // same misclick trap the task rows already had removed.
                MouseArea {
                  id: habitHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                  onContainsMouseChanged: if (containsMouse) {
                    root.cursorActive = false
                    root.syncCursorTo("habit", habitRow.index)
                  }
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    height: Style.space(18)

                    Text {
                      anchors.centerIn: parent
                      text: habitRow.progress.done ? "" : ""
                      color: habitRow.progress.done ? Color.accent : root.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                      id: habitCircleHover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.checkInHabit(habitRow.modelData)
                    }
                  }

                  // Habits have no tag colour, but they keep the same empty
                  // column so their titles line up with the tasks above.
                  Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: Style.space(6)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(44) - streakLabel.implicitWidth
                    elide: Text.ElideRight
                    text: Model.habitLabel(habitRow.modelData, habitRow.progress)
                    color: habitRow.progress.done ? root.muted : root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: streakLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: habitRow.streak > 1 ? habitRow.streak + " " : ""
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---- pomodoro
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.signedIn && root.showPomo

            PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: sectionLabel_focus.implicitHeight

              PanelSectionHeader {
                id: sectionLabel_focus
                anchors.left: parent.left
                text: "FOCUS"
                foreground: root.fg
              }

              PanelSectionHeader {
                anchors.right: parent.right
                anchors.baseline: sectionLabel_focus.baseline
                text: Model.pomoTodayLabel(root.pomoStats, root.pomoPrefs).toUpperCase()
                foreground: root.muted
              }
            }

            Item {
              width: parent.width
              height: Style.space(28)

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""
                  color: root.pomoPhase === "focus" ? Color.accent : root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.icon
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pomoPhase === "idle"
                    ? Model.formatClock(Model.pomoPhaseSeconds("focus", root.pomoPrefs))
                    : root.pomoClock
                  color: root.pomoPhase === "idle" ? root.muted : root.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: root.pomoRunning
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pomoPhase === "idle"
                    ? "ready"
                    : (root.pomoPaused ? "paused" : Model.pomoPhaseLabel(root.pomoPhase).toLowerCase())
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: root.pomoRunning ? "" : ""
                  tooltipText: root.pomoRunning ? "Pause" : (root.pomoPaused ? "Resume" : "Start focus")
                  foreground: root.fg
                  onClicked: {
                    if (root.pomoRunning) root.pausePomo()
                    else if (root.pomoPaused) root.resumePomo()
                    else root.startPomo("focus")
                  }
                }

                PanelActionButton {
                  visible: root.pomoPhase !== "idle"
                  iconText: ""
                  tooltipText: "Discard this block"
                  foreground: root.muted
                  onClicked: root.stopPomo()
                }
              }
            }
          }

          // ---- out to the source of truth. A panel that only shows a
          //      slice of your tasks should say where the rest live.
          Item {
            width: parent.width
            height: Style.space(22)
            visible: root.signedIn

            Row {
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                id: escapeLabel
                text: "Open in TickTick"
                color: escapeHover.containsMouse ? Color.accent : root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.verticalCenter: escapeLabel.verticalCenter
                text: ""
                color: escapeHover.containsMouse ? Color.accent : root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: escapeHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.bar) root.bar.run("xdg-open https://ticktick.com/webapp")
                root.close()
              }
            }
          }

          // ---- footer
          Text {
            width: parent.width
            // While the setup card is up it already explains the situation in
            // the plugin's own terms. Repeating the CLI's "run this command"
            // underneath it contradicts the card, so the cached auth error is
            // suppressed there. A failed connect attempt still surfaces.
            visible: root.actionError !== "" || (root.cacheError !== "" && root.signedIn)
            wrapMode: Text.WordWrap
            text: root.actionError !== "" ? root.actionError : root.cacheError
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  function headerSubtitle() {
    if (!signedIn) return "Not connected"
    if (root.syncing) return "Syncing…"

    var parts = []
    if (showTasks) parts.push(visibleTasks.length + (visibleTasks.length === 1 ? " task" : " tasks"))
    if (showHabits && habits.length > 0) parts.push(habitsRemaining + " of " + habits.length + " habits")

    if (queuedCount > 0) parts.push(queuedCount + " waiting to send")

    var age = staleMinutes
    if (age > 10) parts.push("synced " + age + "m ago")
    return parts.join(" · ")
  }
}

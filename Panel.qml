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

  // ---- cache ------------------------------------------------------------

  property var cache: Model.parseCache("")
  property date nowDate: new Date()

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
  readonly property int refreshIntervalSec: Model.syncIntervalSeconds(setting("syncInterval", "5 minutes"))
  readonly property bool autoSyncs: refreshIntervalSec > 0

  // Rows the user just acted on. Holding them locally means a tick lands
  // instantly instead of after the round trip, and the next sync is what
  // actually removes the row.
  property var pendingIds: ({})
  property var pendingHabitIds: ({})

  // Held actions. Nothing is sent until the window lapses, so undo means
  // the request never happens rather than a second request trying to walk
  // the first one back.
  readonly property int undoSeconds: Math.max(0, parseInt(setting("undoSeconds", 6), 10) || 0)
  property var pendingAction: null
  property int undoTick: 0
  readonly property int undoLeft: pendingAction
    ? Model.undoSecondsLeft(pendingAction.deadline, Date.now() + undoTick * 0)
    : 0

  // ---- pomodoro. The timer is ours; TickTick has no server-side running
  //      clock to join. Finished focus blocks are uploaded so the stats and
  //      history match what its own apps would have recorded.
  readonly property var pomoStats: cache.pomoStats || ({})
  readonly property var pomoPrefs: Model.mergePomoPrefs(cache.pomoPrefs, {
    pomoMinutes: setting("pomoMinutes", 0),
    shortBreakMinutes: setting("shortBreakMinutes", 0),
    longBreakMinutes: setting("longBreakMinutes", 0),
    longBreakInterval: setting("longBreakInterval", 0)
  })
  property string pomoPhase: "idle"
  property real pomoEndMs: 0
  property real pomoPausedLeft: 0
  property int pomoBlocksDone: 0
  property int pomoTick: 0
  readonly property bool pomoRunning: pomoPhase !== "idle" && pomoEndMs > 0
  readonly property bool pomoPaused: pomoPhase !== "idle" && pomoEndMs === 0
  readonly property int pomoSecondsLeft: pomoPaused
    ? Math.round(pomoPausedLeft)
    : (pomoRunning ? Math.max(0, Math.round((pomoEndMs - (Date.now() + pomoTick * 0)) / 1000)) : 0)
  readonly property string pomoClock: pomoPhase === "idle" ? "" : Model.formatClock(pomoSecondsLeft)

  readonly property var allDueTasks: showTasks
    ? Model.dueTasks(cache.tasks, { now: nowDate, horizon: viewHorizon, includeOverdue: includeOverdue })
    : []
  readonly property var visibleTasks: filterPending(allDueTasks)
  readonly property var listedTasks: visibleTasks.slice(0, maxTasks)

  // Tasks typed but not yet confirmed by a sync. Even a scoped sync is most
  // of a second, and a quick-add field that swallows what you typed and
  // shows nothing for that long reads as broken. The row appears on enter;
  // the next cache write replaces it with the real one.
  property var pendingAdds: []
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

  function markPending(taskId) {
    var next = {}
    for (var key in pendingIds) next[key] = pendingIds[key]
    next[taskId] = true
    pendingIds = next
  }

  // ---- lifecycle --------------------------------------------------------

  function open() {
    root.controller.show()
    dataFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    dataFile.reload()
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
  function refresh(force) {
    nowDate = new Date()
    if (syncProc.running) return
    syncProc.command = force === false
      ? [root.cli, "sync", "--max-age", String(Math.max(30, refreshIntervalSec - 15))]
      : [root.cli, "sync"]
    syncProc.running = true
  }

  // Token handoff. The panel writes the pasted value here and the CLI
  // consumes and deletes it, so a full-access credential never travels on a
  // command line where the process table would expose it. The state dir is
  // 0700, so the file is unreadable by other users for the moment it exists.
  readonly property string tokenPastePath: Quickshell.env("HOME") + "/.local/state/omarchy/ticktick/token-paste"

  property FileView tokenFile: FileView {
    path: root.tokenPastePath
    atomicWrites: true
    printErrors: false
  }

  property bool connecting: false

  function connectWithToken() {
    var token = String(tokenPaste.text || "").trim()
    if (token === "") return
    connecting = true
    actionError = ""
    tokenFile.setText(token + "\n")
    tokenPaste.text = ""
    // The CLI waits briefly for this file, which covers FileView's
    // asynchronous save without needing a completion signal here.
    runAction(["login", "--token-file", root.tokenPastePath])
  }

  property FileView dataFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/ticktick/data.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.cache = Model.parseCache(text())
      // The write that lands here is the authority on what is still open,
      // so optimistic rows stop being needed the moment it arrives.
      root.pendingIds = ({})
      root.pendingAdds = []
    }
    onLoadFailed: root.cache = Model.parseCache("")
  }

  Timer {
    id: undoTimer
    interval: 6000
    onTriggered: root.flushPending()
  }

  Timer {
    id: undoTicker
    interval: 250
    repeat: true
    running: root.pendingAction !== null
    onTriggered: root.undoTick++
  }

  Timer {
    id: pomoTicker
    interval: 500
    repeat: true
    running: root.pomoRunning
    onTriggered: {
      root.pomoTick++
      if (root.pomoSecondsLeft <= 0) root.pomoFinished()
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.nowDate = date
  }

  Timer {
    id: syncTimer
    interval: Math.max(60, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.autoSyncs
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // With background sync off, the cache would still be stale on the first
  // paint after a shell restart. One sync at startup is not a background
  // poll; it is the panel having something to show.
  Timer {
    interval: 1500
    running: !root.autoSyncs
    repeat: false
    onTriggered: root.refresh(false)
  }

  // ---- CLI plumbing -----------------------------------------------------

  property string actionError: ""

  Process {
    id: syncProc
    command: [root.cli, "sync"]
    // command is reassigned per call by refresh()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 120)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      root.nowDate = new Date()
    }
  }

  // Mutations are serialized through one process: TickTick answers 429 to
  // bursts, and a queue of at most a few clicks is cheaper than a lockout.
  property var actionQueue: []

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 120)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      root.connecting = false
      root.drainQueue()
    }
  }

  function runAction(args) {
    if (actionProc.running) {
      var queued = actionQueue.slice()
      queued.push(args)
      actionQueue = queued
      return
    }
    actionProc.command = [root.cli].concat(args)
    actionProc.running = true
  }

  function drainQueue() {
    if (actionQueue.length === 0) return
    var queued = actionQueue.slice()
    var next = queued.shift()
    actionQueue = queued
    actionProc.command = [root.cli].concat(next)
    actionProc.running = true
  }

  function scheduleAction(kind, title, args, key) {
    // One pending action at a time: a queue of undoables would need a
    // queue of undo buttons, and the point is a single obvious escape.
    flushPending()
    if (undoSeconds <= 0) {
      runAction(args)
      return
    }
    pendingAction = {
      kind: kind,
      title: title,
      args: args,
      key: key,
      deadline: Date.now() + undoSeconds * 1000
    }
    undoTimer.interval = undoSeconds * 1000
    undoTimer.restart()
  }

  function flushPending() {
    if (!pendingAction) return
    var args = pendingAction.args
    pendingAction = null
    undoTimer.stop()
    runAction(args)
  }

  function cancelPending() {
    if (!pendingAction) return
    var action = pendingAction
    pendingAction = null
    undoTimer.stop()
    if (action.kind === "checkin") clearPendingHabit(action.key)
    else clearPendingTask(action.key)
  }

  function clearPendingTask(taskId) {
    var next = {}
    for (var key in pendingIds) if (key !== taskId) next[key] = pendingIds[key]
    pendingIds = next
  }

  function clearPendingHabit(habitId) {
    var next = {}
    for (var key in pendingHabitIds) if (key !== habitId) next[key] = pendingHabitIds[key]
    pendingHabitIds = next
  }

  function completeTask(task) {
    if (!task || !task.id) return
    markPending(task.id)
    scheduleAction("complete", task.title, ["complete", String(task.id)], String(task.id))
  }

  function checkInHabit(habit) {
    if (!habit || !habit.id) return
    var next = {}
    for (var key in pendingHabitIds) next[key] = pendingHabitIds[key]
    next[String(habit.id)] = true
    pendingHabitIds = next
    scheduleAction("checkin", habit.name, ["checkin", String(habit.id), "--toggle"], String(habit.id))
  }

  // ---- pomodoro control
  function startPomo(phase) {
    pomoPhase = phase
    pomoEndMs = Date.now() + Model.pomoPhaseSeconds(phase, pomoPrefs) * 1000
    pomoPausedLeft = 0
  }

  function pausePomo() {
    if (!pomoRunning) return
    pomoPausedLeft = Math.max(0, (pomoEndMs - Date.now()) / 1000)
    pomoEndMs = 0
  }

  function resumePomo() {
    if (!pomoPaused) return
    pomoEndMs = Date.now() + pomoPausedLeft * 1000
    pomoPausedLeft = 0
  }

  function stopPomo() {
    // A stopped focus block is deliberately not logged. TickTick counts a
    // pomodoro when it completes, and banking partial blocks would inflate
    // the same statistics this exists to keep honest.
    pomoPhase = "idle"
    pomoEndMs = 0
    pomoPausedLeft = 0
  }

  function pomoFinished() {
    if (pomoPhase === "focus") {
      var minutes = Model.pomoPhaseSeconds("focus", pomoPrefs) / 60
      runAction(["pomo", "log", "--minutes", String(minutes)])
      pomoBlocksDone += 1
      startPomo(Model.pomoPhaseAfter(pomoBlocksDone, pomoPrefs))
    } else {
      stopPomo()
    }
  }

  function submitQuickAdd() {
    var title = String(quickAdd.text || "").trim()
    if (title === "") return
    quickAdd.text = ""
    var args = Model.quickAddArgs(title)
    if (!args) return
    // Adding something due later must not file it out of sight. The view
    // widens to wherever the task landed.
    var parsed = Model.parseQuickAdd(title)
    viewHorizon = Model.widerHorizon(viewHorizon, Model.horizonForDue(parsed.due, nowDate))
    // The ghost shows the parsed title, not the raw text, so the syntax is
    // visibly doing something the moment you press enter.
    pendingAdds = pendingAdds.concat([{ id: "", title: args[1], ghost: true }])
    runAction(args)
  }

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
              iconText: syncProc.running ? "" : ""
              tooltipText: syncProc.running ? "Syncing…" : "Sync now"
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

            PanelSectionHeader {
              text: root.overdueCount > 0
                ? "TASKS · " + root.overdueCount + " LATE"
                : "TASKS"
              foreground: root.fg
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
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, taskRow.selected ? 0.14 : 0.08)
                  : "transparent"

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
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: taskRow.tagHex !== ""
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

            PanelSectionHeader {
              text: root.habitsRemaining > 0 ? "HABITS · " + root.habitsRemaining + " LEFT" : "HABITS · DONE"
              foreground: root.fg
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
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, habitRow.selected ? 0.14 : 0.08)
                  : "transparent"

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

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(30) - streakLabel.implicitWidth
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

            PanelSectionHeader {
              text: "FOCUS · " + Model.pomoTodayLabel(root.pomoStats, root.pomoPrefs).toUpperCase()
              foreground: root.fg
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
    if (syncProc.running) return "Syncing…"

    var parts = []
    if (showTasks) parts.push(visibleTasks.length + (visibleTasks.length === 1 ? " task" : " tasks"))
    if (showHabits && habits.length > 0) parts.push(habitsRemaining + " of " + habits.length + " habits")

    if (queuedCount > 0) parts.push(queuedCount + " waiting to send")

    var age = staleMinutes
    if (age > 10) parts.push("synced " + age + "m ago")
    return parts.join(" · ")
  }
}

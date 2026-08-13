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
  moduleName: "colocho.ticktick"
  ipcTarget: "colocho.ticktick"
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
  readonly property int staleMinutes: Model.staleMinutes(cache.syncedAt, nowDate.getTime())

  readonly property int todayStamp: Model.dateStamp(nowDate)

  readonly property bool showTasks: setting("showTasks", true) !== false
  readonly property bool showHabits: setting("showHabits", true) !== false
  readonly property bool showPomo: setting("showPomo", true) !== false
  readonly property string horizon: setting("horizon", "Today")
  readonly property bool includeOverdue: setting("includeOverdue", true) !== false
  readonly property int maxTasks: Math.max(3, parseInt(setting("maxTasks", 12), 10) || 12)
  readonly property int refreshIntervalSec: Math.max(60, parseInt(setting("refreshIntervalSec", 300), 10) || 300)

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
    ? Model.dueTasks(cache.tasks, { now: nowDate, horizon: horizon, includeOverdue: includeOverdue })
    : []
  readonly property var visibleTasks: filterPending(allDueTasks)
  readonly property var listedTasks: visibleTasks.slice(0, maxTasks)
  readonly property int hiddenTaskCount: Math.max(0, visibleTasks.length - listedTasks.length)
  readonly property int overdueCount: Model.overdueCount(visibleTasks, nowDate)

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

  function refresh() {
    nowDate = new Date()
    if (!syncProc.running) syncProc.running = true
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
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- CLI plumbing -----------------------------------------------------

  property string actionError: ""

  Process {
    id: syncProc
    command: [root.cli, "sync"]
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
    // Quick-add from a "what's due" panel means due now, not someday.
    runAction(["add", title, "--due", "today"])
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
      onCloseRequested: root.close()
      onReturnRequested: quickAdd.forceActiveFocus()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "a") quickAdd.forceActiveFocus()
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

              Text {
                text: root.visibleTasks.length === 0 && root.habitsRemaining === 0
                  ? "All clear"
                  : root.horizon
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.headerSubtitle()
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
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
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.signedIn

            PanelSeparator { width: parent.width; foreground: root.fg }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.cache.authRequired
                ? "TickTick signed this session out. Reconnect from a terminal:"
                : "Not connected to TickTick yet. Sign in from a terminal:"
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              wrapMode: Text.WrapAnywhere
              text: root.cli + " login"
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
            placeholderText: "Add a task for today…"
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
              visible: root.listedTasks.length === 0
              text: "Nothing due."
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.listedTasks

              Rectangle {
                id: taskRow
                required property var modelData
                readonly property bool late: Model.isOverdue(modelData, root.nowDate)

                width: content.width
                height: Style.space(26)
                radius: Style.space(4)
                color: taskHover.containsMouse
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                  : "transparent"

                // Row-wide hover for the highlight only. It deliberately
                // accepts no buttons: completion is irreversible from here,
                // so the row must not be a 300px-wide destructive target.
                MouseArea {
                  id: taskHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
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

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(30) - dueLabel.implicitWidth
                    elide: Text.ElideRight
                    text: String(taskRow.modelData.title || "")
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: Model.priorityRank(taskRow.modelData) === "high"
                  }

                  Text {
                    id: dueLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.dueLabel(taskRow.modelData, root.nowDate)
                    color: taskRow.late ? Color.accent : root.muted
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
                readonly property var rawProgress: Model.habitProgress(modelData, root.cache.checkins, root.todayStamp)
                // A held check-in shows as done immediately; undo puts it back.
                readonly property var progress: root.pendingHabitIds[String(modelData.id)]
                  ? { value: rawProgress.goal, goal: rawProgress.goal, ratio: 1, done: true, quantified: rawProgress.quantified }
                  : rawProgress
                readonly property int streak: Model.habitStreak(root.cache.checkins, modelData.id, root.todayStamp)

                width: content.width
                height: Style.space(26)
                radius: Style.space(4)
                color: habitHover.containsMouse
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                  : "transparent"

                // Parity with tasks: the row highlights, the circle acts.
                // Clicking a habit's name used to check it in, which is the
                // same misclick trap the task rows already had removed.
                MouseArea {
                  id: habitHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
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
            visible: root.actionError !== "" || root.cacheError !== ""
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

    var age = staleMinutes
    if (age > 10) parts.push("synced " + age + "m ago")
    return parts.join(" · ")
  }
}

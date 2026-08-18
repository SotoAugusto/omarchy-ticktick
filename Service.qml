import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything that must exist once, not once per screen.
//
// A bar surface is created per monitor, so a two-display desktop runs two of
// every panel. Left in the panel, a timer fires twice, a cache is parsed
// twice, and the focus clock runs twice — two independent countdowns that
// each upload a finished block, inflating the statistics the feature exists
// to keep honest.
//
// The shell mounts a `service` plugin exactly once and hands it to views
// through shell.serviceFor(id), which is how the first-party media plugin
// shares its player state. This holds the cache, the sync timer, the write
// queue, the held-action window, and the focus clock. Panels render it.
Item {
  id: root

  // Injected by the shell when the service is mounted.
  property var shell: null
  property var manifest: null

  // Views hand their inline shell.json settings over; every panel instance
  // has the same ones, so whichever arrives first is as good as any.
  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string cli: pluginDir + "bin/omarchy-ticktick"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/ticktick"

  // ---- cache -------------------------------------------------------------

  property var cache: Model.parseCache("")
  property date nowDate: new Date()

  readonly property bool signedIn: cache.syncedAt > 0 && !cache.authRequired
  readonly property int queuedCount: cache.queued || 0
  readonly property int todayStamp: Model.dateStamp(nowDate)

  property FileView dataFile: FileView {
    path: root.statePath + "/data.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.cache = Model.parseCache(text())
      // The write that lands here is the authority on what is still open, so
      // optimistic rows stop being needed the moment it arrives.
      root.pendingIds = ({})
      root.pendingHabitIds = ({})
      root.pendingAdds = []
    }
    onLoadFailed: root.cache = Model.parseCache("")
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.nowDate = date
  }

  // ---- sync --------------------------------------------------------------

  readonly property int refreshIntervalSec: Model.syncIntervalSeconds(setting("syncInterval", "5 minutes"))
  readonly property bool autoSyncs: refreshIntervalSec > 0
  property string actionError: ""

  // Views show a spinner while this is true.
  readonly property bool syncing: syncProc.running

  // `force` is an explicit user action — opening a panel, the sync button,
  // `r`. A timer tick is not, and passes a max age so a sync another process
  // just completed is not repeated.
  function refresh(force) {
    nowDate = new Date()
    if (syncProc.running) return
    syncProc.command = force === false
      ? [root.cli, "sync", "--max-age", String(Math.max(30, refreshIntervalSec - 15))]
      : [root.cli, "sync"]
    syncProc.running = true
  }

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
      // The CLI just wrote data.json. Reloading here does not depend on the
      // FileView's own watcher, which never attaches if the state directory
      // did not exist yet when this service started — the watcher then has
      // nothing to watch, and every write after that goes unnoticed too.
      root.dataFile.reload()
    }
  }

  Timer {
    id: syncTimer
    interval: Math.max(60, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.autoSyncs
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // With background sync off the cache would still be stale on the first
  // paint after a shell restart. One sync at startup is not a poll; it is the
  // bar having something to show.
  Timer {
    interval: 1500
    running: !root.autoSyncs
    repeat: false
    onTriggered: root.refresh(false)
  }

  // ---- writes ------------------------------------------------------------

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
      // Same reasoning as syncProc: a login, complete, add, etc. just wrote
      // data.json, and the watcher may never have attached (see there).
      root.dataFile.reload()
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

  // ---- held actions ------------------------------------------------------

  property var pendingIds: ({})
  property var pendingHabitIds: ({})
  property var pendingAdds: []

  readonly property int undoSeconds: Math.max(0, parseInt(setting("undoSeconds", 6), 10) || 0)

  // A stack, oldest first. Each entry keeps its own deadline, so completing
  // several things in a row holds all of them rather than sending the earlier
  // ones the moment the next arrives.
  property var pendingActions: []
  property int undoTick: 0

  readonly property var pendingAction: Model.topPending(pendingActions)
  readonly property int pendingCount: pendingActions.length
  readonly property int undoLeft: pendingAction
    ? Model.undoSecondsLeft(pendingAction.deadline, Date.now() + undoTick * 0)
    : 0

  function scheduleAction(kind, title, args, key) {
    if (undoSeconds <= 0) {
      runAction(args)
      return
    }
    pendingActions = pendingActions.concat([{
      kind: kind,
      title: title,
      args: args,
      key: key,
      deadline: Date.now() + undoSeconds * 1000
    }])
  }

  // Anything whose window has closed goes out, oldest first, so the account
  // sees them in the order they were done.
  function flushExpired() {
    var split = Model.expirePending(pendingActions, Date.now())
    if (split.due.length === 0) return
    pendingActions = split.remaining
    for (var i = 0; i < split.due.length; i++) runAction(split.due[i].args)
  }

  // Closing the panel commits everything still held, rather than dropping it.
  function flushPending() {
    if (pendingActions.length === 0) return
    var held = pendingActions
    pendingActions = []
    for (var i = 0; i < held.length; i++) runAction(held[i].args)
  }

  // Undo takes the most recent back, which is the one just done.
  function cancelPending() {
    var action = Model.topPending(pendingActions)
    if (!action) return
    pendingActions = Model.dropTopPending(pendingActions)
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

  function markPending(taskId) {
    var next = {}
    for (var key in pendingIds) next[key] = pendingIds[key]
    next[taskId] = true
    pendingIds = next
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

  function submitEdit(taskId, text) {
    var args = Model.editArgs(taskId, text)
    if (!args) return false
    runAction(args)
    return true
  }

  function submitQuickAdd(text) {
    var args = Model.quickAddArgs(text)
    if (!args) return null
    pendingAdds = pendingAdds.concat([{ id: "", title: args[1], ghost: true }])
    runAction(args)
    return Model.parseQuickAdd(text)
  }

  // One ticker drives both the countdown and expiry, so N held actions do not
  // mean N timers.
  Timer {
    id: undoTicker
    interval: 250
    repeat: true
    running: root.pendingActions.length > 0
    onTriggered: {
      root.undoTick++
      root.flushExpired()
    }
  }

  // ---- focus timer -------------------------------------------------------

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
    // A stopped block is deliberately not logged. TickTick counts a pomodoro
    // on completion, and banking partial blocks would inflate the same
    // statistics this exists to keep honest.
    pomoPhase = "idle"
    pomoEndMs = 0
    pomoPausedLeft = 0
  }

  function togglePomo() {
    if (pomoRunning) pausePomo()
    else if (pomoPaused) resumePomo()
    else startPomo("focus")
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

  // ---- connecting --------------------------------------------------------

  property bool connecting: false

  property FileView tokenFile: FileView {
    path: root.statePath + "/token-paste"
    atomicWrites: true
    printErrors: false
  }

  function connectWithToken(token) {
    var trimmed = String(token || "").trim()
    if (trimmed === "") return
    connecting = true
    actionError = ""
    tokenFile.setText(trimmed + "\n")
    // The CLI waits briefly for this file, which covers FileView's
    // asynchronous save without needing a completion signal here.
    runAction(["login", "--token-file", root.statePath + "/token-paste"])
  }
}

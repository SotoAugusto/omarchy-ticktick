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

  // A panel hands these over a moment after the service mounts, and again
  // whenever they change — turning notifications on should take effect then
  // rather than at the next minute boundary. Repeat calls are free: the
  // announced-keys map makes the check idempotent.
  onSettingsChanged: checkDueNotifications()

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
      // A sync can pull in a task that is due already, which should not wait
      // for the next minute boundary to be announced.
      root.checkDueNotifications()
    }
    onLoadFailed: root.cache = Model.parseCache("")
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.nowDate = date
      // This wakeup already exists for the bar's labels; the due check rides
      // it rather than adding a timer of its own.
      root.checkDueNotifications()
    }
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

  // A checkbox flip goes out immediately — no undo window. The undo stack
  // exists for completions, which roll recurring tasks forward and cannot be
  // unrolled; a checkbox is its own undo. True when the flip was dispatched,
  // so the row only shows its pending state for a write that is on its way.
  function toggleSubtask(task, item) {
    if (!task || !task.id || !item || !item.id) return false
    runAction(["subtask", String(task.id), String(item.id)])
    return true
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

  // ---- due notifications -------------------------------------------------
  //
  // The bar count is a thing you have to look at. This is the push half: when
  // a task's moment arrives, the desktop says so.
  //
  // Nothing here polls. The clock above already wakes once a minute to move
  // `nowDate`, so the check rides along; a timer of its own would be a second
  // wakeup source, unaligned to the minute, for no better answer.

  readonly property bool notifiesDue: setting("notifyOnDue", false) === true
  readonly property int notifyLeadMinutes: Math.max(0, parseInt(setting("notifyLeadMinutes", 0), 10) || 0)

  // Which moments have already been announced. Kept on disk because the shell
  // restarts on every theme or config change: held in memory alone, a reload
  // at 14:31 would announce the 14:30 meeting a second time. Written only when
  // something fires, so a quiet day costs no writes at all.
  //
  // It does not grow without bound. Model.dueNotifications rebuilds it from
  // the current task list each pass and drops every key older than its
  // catch-up window, so it holds what fired in the last hour — a handful of
  // entries, not a session-long ledger.
  property var notifiedKeys: ({})
  property bool notifiedLoaded: false

  property FileView notifiedFile: FileView {
    path: root.statePath + "/notified.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.notifiedKeys = Model.parseNotified(text())
      root.notifiedLoaded = true
      root.checkDueNotifications()
    }
    // No file yet is the ordinary first run, not an error.
    onLoadFailed: {
      root.notifiedKeys = ({})
      root.notifiedLoaded = true
      root.checkDueNotifications()
    }
  }

  function checkDueNotifications() {
    if (!notifiesDue) return
    // Announcing before the file has been read would repeat whatever it
    // holds; it lands within milliseconds of startup.
    if (!notifiedLoaded) return

    var tasks = cache.tasks || []
    // An empty cache is a cache that has not loaded, not an empty account.
    // Rebuilding the map from it would forget what was announced and say it
    // all again when the tasks come back.
    if (tasks.length === 0) return

    var result = Model.dueNotifications(tasks, nowDate, notifiedKeys, {
      leadMinutes: notifyLeadMinutes,
      skipIds: pendingIds
    })
    notifiedKeys = result.notified
    if (result.due.length === 0) return

    // Saved before the notification is sent: a crash between the two costs a
    // missed reminder, the other order costs a duplicate on every restart.
    notifiedFile.setText(JSON.stringify(result.notified) + "\n")

    var args = Model.notifyArgs(result.due, nowDate)
    if (args) sendNotification(args)
  }

  // One notification per batch means one process per check at most, so this
  // queue is only ever holding a second batch — the minute tick and a cache
  // reload can land back to back, and a Process cannot be re-commanded while
  // it runs.
  property var notifyQueue: []

  function sendNotification(args) {
    if (notifyProc.running) {
      notifyQueue = notifyQueue.concat([args])
      return
    }
    notifyProc.command = ["notify-send"].concat(args)
    notifyProc.running = true
  }

  function drainNotifyQueue() {
    if (notifyQueue.length === 0) return
    var queued = notifyQueue.slice()
    var next = queued.shift()
    notifyQueue = queued
    notifyProc.command = ["notify-send"].concat(next)
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    // A missing libnotify is a setup problem, not a sync failure, so it stays
    // out of the panel's error line — which is reserved for what the CLI said.
    onExited: root.drainNotifyQueue()
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

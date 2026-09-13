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
  //
  // Deferred, because this handler runs before the bindings that read the
  // same settings do. Called straight, the check sees the previous values:
  // switching notifications on was a no-op, and switching them off ran one
  // last pass with the old `true` and could fire a popup on the way out.
  onSettingsChanged: Qt.callLater(checkDueNotifications)

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
  // Clamped to the range the settings UI offers, so a hand-edited shell.json
  // cannot arm a reminder days ahead of the thing it is reminding about.
  readonly property int notifyLeadMinutes:
    Math.max(0, Math.min(120, parseInt(setting("notifyLeadMinutes", 0), 10) || 0))

  // Which moments have already been announced. Kept on disk because the shell
  // restarts on every theme or config change: held in memory alone, a reload
  // at 14:31 would announce the 14:30 meeting a second time. Written only when
  // notify-send has confirmed a batch, or when switching the feature on
  // records what is already past, so a quiet day costs no writes at all.
  //
  // It does not grow without bound. Model.dueNotifications rebuilds it each
  // pass and drops every key older than its catch-up window, so it holds what
  // fired in the last hour — a handful of entries, not a session-long ledger.
  property var notifiedKeys: ({})
  property bool notifiedLoaded: false

  // Whether the next pass should record what is already past instead of
  // announcing it. That is for switching the feature on, and never for a
  // restart. A first run has no file yet; a switch inside a running session
  // is off-then-on as seen from here. A restart is the gap the catch-up window
  // exists for, however long ago the last reminder was, so it announces what
  // came due while the shell was down.
  property bool notifyAdopts: false
  // Set once the feature has been seen switched off in this session. Turning
  // it on at startup is the settings arriving, not the user, and must not
  // count; turning it on after it was off is the user.
  property bool notifyWasSwitchedOff: false

  onNotifiesDueChanged: {
    if (!notifiesDue) {
      notifyWasSwitchedOff = true
    } else if (notifyWasSwitchedOff) {
      notifyWasSwitchedOff = false
      notifyAdopts = true
    }
  }

  property FileView notifiedFile: FileView {
    path: root.statePath + "/notified.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.notifiedKeys = Model.parseNotified(text())
      root.notifiedLoaded = true
      root.checkDueNotifications()
    }
    // No file yet is the ordinary first run, not an error — and a first run
    // has nothing to catch up from.
    onLoadFailed: {
      root.notifiedKeys = ({})
      root.notifiedLoaded = true
      root.notifyAdopts = true
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

    var adopting = notifyAdopts
    var result = Model.dueNotifications(tasks, nowDate, notifiedKeys, {
      leadMinutes: notifyLeadMinutes,
      skipIds: notifySkipIds(),
      adopt: adopting
    })

    // Held in memory straight away, including the batch about to go out, so a
    // second check this minute does not announce the same moments again while
    // the first is still on its way to the desktop. The file is the durable
    // half and only gets what has been confirmed.
    notifiedKeys = result.notified

    if (adopting) {
      notifyAdopts = false
      saveNotified()
    }

    if (result.due.length === 0) return
    var args = Model.notifyArgs(result.due, nowDate)
    if (!args) return
    var keys = []
    for (var i = 0; i < result.due.length; i++) keys.push(Model.notifyKey(result.due[i]))
    sendNotification(args, keys)
  }

  // Every task whose completion is waiting, not only the rows hidden right
  // now. A data.json reload clears pendingIds before a held completion has
  // been sent, and without the held actions the task you just checked off
  // would announce itself on the very next check.
  function notifySkipIds() {
    var skip = {}
    for (var id in pendingIds) skip[id] = true
    for (var i = 0; i < pendingActions.length; i++) {
      if (pendingActions[i].kind === "complete") skip[String(pendingActions[i].key)] = true
    }
    return skip
  }

  // One notification per batch means one process per check at most, so this
  // queue is only ever holding a second batch — the minute tick and a cache
  // reload can land back to back, and a Process cannot be re-commanded while
  // it runs.
  property var notifyQueue: []

  // Whether a batch is already on its way out. Not `notifyProc.running`: that
  // does not go true until the event loop turns, so two sends in one turn both
  // read it as false and the second overwrites the first's command before it
  // ever starts — the batch is not queued, it is lost.
  property bool notifySending: false

  // Keys of every batch still queued or running. They count as announced in
  // memory, but stay out of the file until notify-send has confirmed them.
  // Bookkeeping per batch rather than a snapshot of the whole map: a snapshot
  // taken while an earlier batch was still unconfirmed carried that batch's
  // keys, so restoring or writing it recorded a reminder nobody had seen.
  property var notifyUnconfirmed: ({})
  // The keys of the batch notify-send is running for right now.
  property var notifyInFlight: []

  // Recording before the send is what made a missing notify-send permanent:
  // the moment was marked announced, so installing libnotify afterwards did
  // not bring it back.
  function sendNotification(args, keys) {
    var batch = { args: args, keys: keys instanceof Array ? keys : [] }
    var waiting = {}
    for (var key in notifyUnconfirmed) waiting[key] = true
    for (var i = 0; i < batch.keys.length; i++) waiting[batch.keys[i]] = true
    notifyUnconfirmed = waiting
    if (notifySending) {
      notifyQueue = notifyQueue.concat([batch])
      return
    }
    startNotification(batch)
  }

  function startNotification(batch) {
    notifySending = true
    notifyInFlight = batch.keys
    notifyProc.command = ["notify-send"].concat(batch.args)
    notifyProc.running = true
  }

  // Takes the running batch's keys off the waiting list and hands them back.
  function releaseInFlight() {
    var released = notifyInFlight
    notifyInFlight = []
    if (released.length === 0) return released
    var waiting = {}
    for (var key in notifyUnconfirmed) waiting[key] = true
    for (var i = 0; i < released.length; i++) delete waiting[released[i]]
    notifyUnconfirmed = waiting
    return released
  }

  // Writes what the desktop has actually been shown: the whole map, minus
  // anything still waiting for its own confirmation.
  function saveNotified() {
    var confirmed = {}
    for (var key in notifiedKeys) {
      if (notifiedKeys[key] && !notifyUnconfirmed[key]) confirmed[key] = true
    }
    notifiedFile.setText(JSON.stringify(confirmed) + "\n")
  }

  // notify-send exited cleanly, so the desktop has this batch.
  function commitNotified() {
    releaseInFlight()
    saveNotified()
  }

  // It did not: no notify-send on PATH, or no daemon listening. Forget exactly
  // this batch's moments, so the next check tries them again, and nothing else.
  function rollbackNotified() {
    var failed = releaseInFlight()
    if (failed.length === 0) return
    var next = {}
    for (var key in notifiedKeys) next[key] = notifiedKeys[key]
    for (var i = 0; i < failed.length; i++) delete next[failed[i]]
    notifiedKeys = next
  }

  function drainNotifyQueue() {
    // A batch that never started has no exit to report it, so whatever is
    // still marked in flight here did not arrive.
    if (notifyInFlight.length > 0) rollbackNotified()
    if (notifyQueue.length === 0) {
      notifySending = false
      return
    }
    var queued = notifyQueue.slice()
    var next = queued.shift()
    notifyQueue = queued
    startNotification(next)
  }

  Process {
    id: notifyProc
    // A missing libnotify is a setup problem, not a sync failure, so it stays
    // out of the panel's error line — which is reserved for what the CLI said.
    //
    // Draining on `running` rather than on `exited`, because a binary that is
    // not there never exits: it fails to start, and only `running` moves. Off
    // `exited` alone, one absent notify-send would strand the queue and every
    // later batch behind it.
    //
    // `exited` settles the batch it can see: a clean exit confirms it, and any
    // other code — no daemon listening — sends it back to be tried again. Qt
    // emits `exited` before `running` goes false, so the drain below only
    // finds a batch still in flight when the process never started at all.
    onExited: function(code) {
      if (code === 0) root.commitNotified()
      else root.rollbackNotified()
    }
    onRunningChanged: if (!running) root.drainNotifyQueue()
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

// Pure data shaping for the TickTick widget. No QML types in here on
// purpose: everything below is plain JS so it can be exercised by node in
// tests/ without a running shell (see tests/model.test.js).

var STATUS_TODO = 0
var STATUS_WONT_DO = -1
var STATUS_DONE = 2

var CHECKIN_DONE = 2

// ---- dates -------------------------------------------------------------

// TickTick serializes with a numeric offset ("+0000"), which Date.parse
// only handles by accident. Normalizing to "+00:00" makes it an ISO string
// every engine agrees on.
function parseApiDate(value) {
  if (!value) return null
  var text = String(value).trim()
  if (text === "") return null
  if (text.length >= 5 && (text.charAt(text.length - 5) === "+" || text.charAt(text.length - 5) === "-")
      && text.charAt(text.length - 3) !== ":") {
    text = text.slice(0, -2) + ":" + text.slice(-2)
  }
  var parsed = new Date(text)
  return isNaN(parsed.getTime()) ? null : parsed
}

// An all-day task is a calendar date wearing a timestamp. Converting it
// through the local zone is how "due today" becomes "due yesterday" for
// anyone west of UTC, so the date part is read literally instead.
function taskDueDate(task) {
  if (!task || !task.dueDate) return null
  if (task.isAllDay) {
    var head = String(task.dueDate).slice(0, 10).split("-")
    if (head.length === 3) {
      var day = new Date(Number(head[0]), Number(head[1]) - 1, Number(head[2]))
      return isNaN(day.getTime()) ? null : day
    }
  }
  return parseApiDate(task.dueDate)
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function endOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59, 999)
}

function addDays(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days)
}

function dateStamp(date) {
  var month = date.getMonth() + 1
  var day = date.getDate()
  return date.getFullYear() * 10000 + month * 100 + day
}

function stampToDate(stamp) {
  var text = String(stamp)
  if (text.length !== 8) return null
  return new Date(Number(text.slice(0, 4)), Number(text.slice(4, 6)) - 1, Number(text.slice(6, 8)))
}

// ---- tasks -------------------------------------------------------------

function horizonDays(horizon) {
  if (horizon === "Tomorrow") return 1
  if (horizon === "Next 7 days") return 7
  return 0
}

function isOpen(task) {
  return task && task.status !== STATUS_DONE && task.status !== STATUS_WONT_DO && !task.deleted
}

function isOverdue(task, now) {
  var due = taskDueDate(task)
  if (!due) return false
  if (task.isAllDay) return dateStamp(due) < dateStamp(now)
  return due.getTime() < now.getTime()
}

// Tasks worth showing: open, dated, and landing inside the horizon —
// plus anything already late when the user asked to see late work.
function dueTasks(tasks, options) {
  var opts = options || {}
  var now = opts.now || new Date()
  var includeOverdue = opts.includeOverdue !== false
  var cutoff = endOfDay(addDays(now, horizonDays(opts.horizon))).getTime()
  var todayStamp = dateStamp(now)

  var result = []
  for (var i = 0; i < (tasks || []).length; i++) {
    var task = tasks[i]
    if (!isOpen(task)) continue

    var due = taskDueDate(task)
    if (!due) continue

    var late = isOverdue(task, now)
    if (late && !includeOverdue) continue

    var dueValue = task.isAllDay ? endOfDay(due).getTime() : due.getTime()
    if (!late && dueValue > cutoff) continue

    result.push(task)
  }

  result.sort(function(a, b) {
    var aLate = isOverdue(a, now) ? 0 : 1
    var bLate = isOverdue(b, now) ? 0 : 1
    if (aLate !== bLate) return aLate - bLate

    var aDue = taskDueDate(a)
    var bDue = taskDueDate(b)
    var aTime = aDue ? aDue.getTime() : 0
    var bTime = bDue ? bDue.getTime() : 0
    if (aTime !== bTime) return aTime - bTime

    // TickTick's own tiebreak: higher priority first, then manual order.
    var aPriority = Number(a.priority || 0)
    var bPriority = Number(b.priority || 0)
    if (aPriority !== bPriority) return bPriority - aPriority
    return Number(a.sortOrder || 0) - Number(b.sortOrder || 0)
  })

  return result
}

function nextTask(tasks) {
  return (tasks && tasks.length > 0) ? tasks[0] : null
}

function dueLabel(task, now) {
  var due = taskDueDate(task)
  if (!due) return ""
  var reference = now || new Date()
  var dayDelta = Math.round((startOfDay(due).getTime() - startOfDay(reference).getTime()) / 86400000)

  if (task.isAllDay) {
    if (dayDelta === 0) return "Today"
    if (dayDelta === 1) return "Tomorrow"
    if (dayDelta === -1) return "Yesterday"
    if (dayDelta < 0) return Math.abs(dayDelta) + "d late"
    return dayDelta + "d"
  }

  var clock = pad2(due.getHours()) + ":" + pad2(due.getMinutes())
  if (dayDelta === 0) return clock
  if (dayDelta === 1) return "Tmw " + clock
  if (dayDelta === -1) return "Yst " + clock
  if (dayDelta < 0) return Math.abs(dayDelta) + "d late"
  return dayDelta + "d " + clock
}

function pad2(value) {
  return value < 10 ? "0" + value : String(value)
}

// TickTick priorities: 0 none, 1 low, 3 medium, 5 high.
function priorityRank(task) {
  var value = Number((task && task.priority) || 0)
  if (value >= 5) return "high"
  if (value >= 3) return "medium"
  if (value >= 1) return "low"
  return "none"
}

function projectName(projects, projectId, inboxId) {
  if (projectId && projectId === inboxId) return "Inbox"
  for (var i = 0; i < (projects || []).length; i++) {
    if (projects[i].id === projectId) return projects[i].name || ""
  }
  return ""
}

// ---- tags --------------------------------------------------------------

// Tasks reference tags by their lowercase `name`; the colour lives on the
// tag object. A task can carry several, and the first one in TickTick's own
// order is the one its apps lead with, so that is the dot we paint.
function tagIndex(tags) {
  var index = {}
  for (var i = 0; i < (tags || []).length; i++) {
    var tag = tags[i]
    if (tag && tag.name) index[String(tag.name)] = tag
  }
  return index
}

function firstTag(task, index) {
  var names = (task && task.tags) || []
  for (var i = 0; i < names.length; i++) {
    var tag = index[String(names[i])]
    if (tag) return tag
  }
  return null
}

function tagColor(task, index) {
  var tag = firstTag(task, index)
  return tag && tag.color ? String(tag.color) : ""
}

function tagLabel(task, index) {
  var tag = firstTag(task, index)
  return tag ? String(tag.label || tag.name || "") : ""
}

// ---- quick add ---------------------------------------------------------

// Inline syntax for the quick-add field. `#tag` and plain date words are
// TickTick's own conventions, so they behave the way its apps taught you.
// `!` for priority is this plugin's: TickTick has no quick-add symbol for
// it, so nothing is being contradicted by inventing one.
var PRIORITY_WORDS = {
  "1": 5, "high": 5, "h": 5,
  "2": 3, "medium": 3, "med": 3, "m": 3,
  "3": 1, "low": 1, "l": 1,
  "0": 0, "none": 0
}

function parseQuickAdd(text) {
  var rest = String(text || "")
  var tags = []
  var priority = 0
  var due = "today"

  rest = rest.replace(/(^|\s)#([^\s#]+)/g, function(match, lead, tag) {
    tags.push(String(tag).toLowerCase())
    return lead
  })

  rest = rest.replace(/(^|\s)!([A-Za-z0-9]+)/g, function(match, lead, word) {
    var mapped = PRIORITY_WORDS[String(word).toLowerCase()]
    if (mapped === undefined) return match
    priority = mapped
    return lead
  })

  // Only a trailing date word is treated as a date. "Call mum today" sets a
  // date; "Plan today's standup" keeps its word.
  // The preposition goes with the date. Without this, "notes for today"
  // becomes a task called "notes for".
  var dateMatch = rest.match(/\s(?:for\s+|on\s+|due\s+|by\s+)?(today|tomorrow|\d{4}-\d{2}-\d{2})\s*$/i)
  if (dateMatch) {
    due = dateMatch[1].toLowerCase()
    rest = rest.slice(0, dateMatch.index)
  }

  return {
    title: rest.replace(/\s+/g, " ").trim(),
    tags: tags,
    priority: priority,
    due: due
  }
}

function quickAddArgs(text) {
  var parsed = parseQuickAdd(text)
  if (parsed.title === "") return null
  var args = ["add", parsed.title, "--due", parsed.due]
  if (parsed.priority > 0) args = args.concat(["--priority", String(parsed.priority)])
  if (parsed.tags.length > 0) args = args.concat(["--tags", parsed.tags.join(",")])
  return args
}

// ---- due tiers ---------------------------------------------------------

// TickTick has no colour for "overdue" or "today" — every client paints that
// itself. Returning a tier instead of a colour keeps the decision in the
// panel, where the theme's palette lives.
function dueTier(task, now) {
  if (isOverdue(task, now)) return "overdue"
  var due = taskDueDate(task)
  if (!due) return "upcoming"
  return dateStamp(due) === dateStamp(now || new Date()) ? "today" : "upcoming"
}

// ---- habits ------------------------------------------------------------

function checkinFor(checkins, habitId, stamp) {
  var entries = (checkins && checkins[habitId]) || []
  for (var i = 0; i < entries.length; i++) {
    if (Number(entries[i].checkinStamp) === Number(stamp)) return entries[i]
  }
  return null
}

function habitProgress(habit, checkins, stamp) {
  var goal = Number((habit && habit.goal) || 1) || 1
  var entry = checkinFor(checkins, habit ? habit.id : "", stamp)
  var value = entry ? Number(entry.value || 0) : 0
  var status = entry ? Number(entry.status || 0) : 0
  return {
    value: value,
    goal: goal,
    ratio: goal > 0 ? Math.min(1, value / goal) : 0,
    done: status === CHECKIN_DONE || value >= goal,
    quantified: String(habit && habit.type) === "Real"
  }
}

// Consecutive completed days ending today, or ending yesterday when today
// is still open — a streak shouldn't read as broken at 9am.
function habitStreak(checkins, habitId, todayStamp) {
  var entries = (checkins && checkins[habitId]) || []
  var done = {}
  for (var i = 0; i < entries.length; i++) {
    if (Number(entries[i].status) === CHECKIN_DONE) done[Number(entries[i].checkinStamp)] = true
  }

  var cursor = stampToDate(todayStamp)
  if (!cursor) return 0
  if (!done[Number(todayStamp)]) cursor = addDays(cursor, -1)

  var streak = 0
  while (done[dateStamp(cursor)]) {
    streak++
    cursor = addDays(cursor, -1)
  }
  return streak
}

function habitLabel(habit, progress) {
  if (!progress.quantified) return habit.name
  var unit = habit.unit ? " " + habit.unit : ""
  return habit.name + "  " + trimNumber(progress.value) + "/" + trimNumber(progress.goal) + unit
}

function trimNumber(value) {
  var number = Number(value || 0)
  return number % 1 === 0 ? String(number) : number.toFixed(1)
}

function habitsRemaining(habits, checkins, stamp) {
  var count = 0
  for (var i = 0; i < (habits || []).length; i++) {
    if (!habitProgress(habits[i], checkins, stamp).done) count++
  }
  return count
}

// ---- bar label ---------------------------------------------------------

function barLabel(mode, tasks, habitsLeft, now) {
  if (mode === "Icon") return ""

  if (mode === "Next") {
    var next = nextTask(tasks)
    if (!next) return habitsLeft > 0 ? habitsLeft + " habits" : ""
    return elide(String(next.title || ""), 28)
  }

  var parts = []
  if (tasks && tasks.length > 0) parts.push(String(tasks.length))
  if (habitsLeft > 0) parts.push(habitsLeft + "♦")
  return parts.join("  ")
}

function elide(text, limit) {
  if (text.length <= limit) return text
  return text.slice(0, Math.max(1, limit - 1)) + "…"
}

function overdueCount(tasks, now) {
  var count = 0
  for (var i = 0; i < (tasks || []).length; i++) {
    if (isOverdue(tasks[i], now)) count++
  }
  return count
}

// ---- pomodoro ----------------------------------------------------------

function formatClock(seconds) {
  var total = Math.max(0, Math.round(seconds))
  var mins = Math.floor(total / 60)
  var secs = total % 60
  if (mins >= 60) {
    var hours = Math.floor(mins / 60)
    return hours + ":" + pad2(mins % 60) + ":" + pad2(secs)
  }
  return pad2(mins) + ":" + pad2(secs)
}

// TickTick's own cycle: focus, short break, focus, ... and a long break
// every `longBreakInterval` focus blocks. Mirroring it means a session
// logged here lands in the same rhythm the phone app would have used.
function pomoPhaseAfter(completedFocusBlocks, prefs) {
  var settings = prefs || {}
  var interval = Math.max(1, Number(settings.longBreakInterval || 4))
  var done = Math.max(0, Number(completedFocusBlocks || 0))
  return (done > 0 && done % interval === 0) ? "longBreak" : "shortBreak"
}

// Account settings are the default; a non-zero plugin setting wins. Zero
// means "whatever TickTick says", so the panel follows the phone app until
// the user deliberately disagrees with it.
function mergePomoPrefs(prefs, overrides) {
  var base = prefs || {}
  var over = overrides || {}

  function pick(overrideValue, baseValue, fallback) {
    var chosen = Number(overrideValue || 0)
    if (chosen > 0) return chosen
    var inherited = Number(baseValue || 0)
    return inherited > 0 ? inherited : fallback
  }

  return {
    pomoDuration: pick(over.pomoMinutes, base.pomoDuration, 25),
    shortBreakDuration: pick(over.shortBreakMinutes, base.shortBreakDuration, 5),
    longBreakDuration: pick(over.longBreakMinutes, base.longBreakDuration, 15),
    longBreakInterval: pick(over.longBreakInterval, base.longBreakInterval, 4),
    pomoGoal: Number(base.pomoGoal || 0)
  }
}

function pomoPhaseSeconds(phase, prefs) {
  var settings = prefs || {}
  if (phase === "shortBreak") return Math.max(1, Number(settings.shortBreakDuration || 5)) * 60
  if (phase === "longBreak") return Math.max(1, Number(settings.longBreakDuration || 15)) * 60
  return Math.max(1, Number(settings.pomoDuration || 25)) * 60
}

function pomoPhaseLabel(phase) {
  if (phase === "shortBreak") return "Short break"
  if (phase === "longBreak") return "Long break"
  return "Focus"
}

function pomoTodayLabel(stats, prefs) {
  var count = Number((stats || {}).todayPomoCount || 0)
  var goal = Number((prefs || {}).pomoGoal || 0)
  var minutes = Number((stats || {}).todayPomoDuration || 0)
  var head = goal > 0 ? count + "/" + goal + " today" : count + " today"
  return minutes > 0 ? head + " · " + minutes + "m" : head
}

// ---- undo --------------------------------------------------------------

// Actions are held, not sent and then reversed. Completing a recurring task
// rolls it to its next occurrence, and reopening afterwards does not put
// that back — so the only honest undo is one that happens before the
// request leaves.
function undoSecondsLeft(deadlineMs, nowMs) {
  if (!deadlineMs) return 0
  return Math.max(0, Math.ceil((deadlineMs - (nowMs || Date.now())) / 1000))
}

function undoLabel(pending, secondsLeft) {
  if (!pending) return ""
  var name = elide(String(pending.title || ""), 24)
  var verb = pending.kind === "checkin" ? "Checked in" : "Completed"
  return verb + " " + name + " · undo " + secondsLeft + "s"
}

// ---- cache -------------------------------------------------------------

function parseCache(text) {
  var empty = {
    syncedAt: 0,
    inboxId: "",
    projects: [],
    tasks: [],
    habits: [],
    checkins: {},
    todayStamp: 0,
    queued: 0,
    tags: [],
    pomoStats: {},
    pomoPrefs: {},
    authRequired: false,
    error: null
  }
  if (!text) return empty
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return empty
    return {
      syncedAt: Number(parsed.syncedAt || 0),
      inboxId: String(parsed.inboxId || ""),
      projects: parsed.projects || [],
      tasks: parsed.tasks || [],
      habits: parsed.habits || [],
      checkins: parsed.checkins || {},
      todayStamp: Number(parsed.todayStamp || 0),
      queued: Number(parsed.queued || 0),
      tags: parsed.tags || [],
      pomoStats: parsed.pomoStats || {},
      pomoPrefs: parsed.pomoPrefs || {},
      authRequired: !!parsed.authRequired,
      error: parsed.error || null
    }
  } catch (e) {
    return empty
  }
}

function staleMinutes(syncedAt, now) {
  if (!syncedAt) return -1
  return Math.floor(((now || Date.now()) - syncedAt) / 60000)
}

// QML imports this file directly; node needs the same functions as a module
// so the logic above can be tested without a shell.
if (typeof module !== "undefined") {
  module.exports = {
    parseApiDate: parseApiDate,
    taskDueDate: taskDueDate,
    startOfDay: startOfDay,
    endOfDay: endOfDay,
    addDays: addDays,
    dateStamp: dateStamp,
    stampToDate: stampToDate,
    horizonDays: horizonDays,
    isOpen: isOpen,
    isOverdue: isOverdue,
    dueTasks: dueTasks,
    nextTask: nextTask,
    dueLabel: dueLabel,
    priorityRank: priorityRank,
    tagIndex: tagIndex,
    firstTag: firstTag,
    tagColor: tagColor,
    tagLabel: tagLabel,
    dueTier: dueTier,
    parseQuickAdd: parseQuickAdd,
    quickAddArgs: quickAddArgs,
    projectName: projectName,
    checkinFor: checkinFor,
    habitProgress: habitProgress,
    habitStreak: habitStreak,
    habitLabel: habitLabel,
    habitsRemaining: habitsRemaining,
    barLabel: barLabel,
    elide: elide,
    overdueCount: overdueCount,
    formatClock: formatClock,
    pomoPhaseAfter: pomoPhaseAfter,
    mergePomoPrefs: mergePomoPrefs,
    pomoPhaseSeconds: pomoPhaseSeconds,
    pomoPhaseLabel: pomoPhaseLabel,
    pomoTodayLabel: pomoTodayLabel,
    undoSecondsLeft: undoSecondsLeft,
    undoLabel: undoLabel,
    parseCache: parseCache,
    staleMinutes: staleMinutes
  }
}

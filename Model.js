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

// A task with a duration keeps its start in `startDate`, while `dueDate`
// becomes the end of the block — which is why "Meeting 8:30–9:30" read as
// 9:30 everywhere. An ordinary timed task carries the same instant in both
// fields, so only a start that really moves earlier counts as a span.
function taskStartDate(task) {
  if (!task || task.isAllDay) return null
  if (!task.startDate || !task.dueDate) return null
  var start = parseApiDate(task.startDate)
  var due = taskDueDate(task)
  if (!start || !due) return null
  if (start.getTime() >= due.getTime()) return null
  return start
}

// The instant a task "happens": the start of a duration, otherwise the due
// time. Sorting and the horizon cutoff share it, so a meeting is placed by
// when it begins and one starting late tonight is not pushed out of the
// Today view by its after-midnight end.
function taskTimeKey(task) {
  return taskStartDate(task) || taskDueDate(task)
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

var HORIZONS = ["Today", "Tomorrow", "Next 7 days"]

function horizons() {
  return HORIZONS
}

function horizonIndex(horizon) {
  var i = HORIZONS.indexOf(String(horizon))
  return i < 0 ? 0 : i
}

function cycleHorizon(current, delta) {
  var i = HORIZONS.indexOf(String(current))
  if (i < 0) i = 0
  var next = i + (delta || 1)
  // Wraps, so one key or one click can reach every view without a second
  // control for going back.
  if (next >= HORIZONS.length) next = 0
  if (next < 0) next = HORIZONS.length - 1
  return HORIZONS[next]
}

// The narrowest view that would still show a task due on `dueWord`. Used so
// adding "…tomorrow" from a Today view does not file the task somewhere the
// user cannot see it.
function horizonForDue(dueWord, now) {
  var word = String(dueWord || "today").toLowerCase()
  if (word === "today" || word === "yesterday") return "Today"
  if (word === "tomorrow") return "Tomorrow"

  var parts = word.split("-")
  if (parts.length === 3) {
    var target = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    if (!isNaN(target.getTime())) {
      var days = Math.round((startOfDay(target).getTime() - startOfDay(now || new Date()).getTime()) / 86400000)
      if (days <= 0) return "Today"
      if (days === 1) return "Tomorrow"
      if (days <= 7) return "Next 7 days"
      // Further out than any view reaches; the widest is the best on offer.
      return "Next 7 days"
    }
  }
  return "Today"
}

function widerHorizon(a, b) {
  return HORIZONS.indexOf(a) >= HORIZONS.indexOf(b) ? a : b
}

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

    var dueValue = task.isAllDay ? endOfDay(due).getTime() : taskTimeKey(task).getTime()
    if (!late && dueValue > cutoff) continue

    result.push(task)
  }

  result.sort(function(a, b) {
    var aLate = isOverdue(a, now) ? 0 : 1
    var bLate = isOverdue(b, now) ? 0 : 1
    if (aLate !== bLate) return aLate - bLate

    // A duration is an appointment: it is pinned to a moment you have to
    // show up for, while a plain due time floats anywhere in its day. Among
    // everything that is not late, the pinned moments go first — otherwise
    // an evening block drowns under every all-day task, whose key is
    // midnight and so always sorts ahead by time alone.
    var aSpan = taskStartDate(a) ? 0 : 1
    var bSpan = taskStartDate(b) ? 0 : 1
    if (aSpan !== bSpan) return aSpan - bSpan

    var aKey = taskTimeKey(a)
    var bKey = taskTimeKey(b)
    var aTime = aKey ? aKey.getTime() : 0
    var bTime = bKey ? bKey.getTime() : 0
    if (aTime !== bTime) return aTime - bTime

    // TickTick's own tiebreak: higher priority first, then manual order.
    var aPriority = Number(a.priority || 0)
    var bPriority = Number(b.priority || 0)
    if (aPriority !== bPriority) return bPriority - aPriority
    return Number(a.sortOrder || 0) - Number(b.sortOrder || 0)
  })

  return result
}

function nextTaskTitle(tasks) {
  var next = nextTask(tasks)
  return next ? String(next.title || "") : ""
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

  // A duration shows the whole block, and the day marker follows the start:
  // the question the label answers is "when does this begin". A past span
  // stays compact — how long it ran matters less than how late it is.
  var start = taskStartDate(task)
  if (start) {
    var startDelta = Math.round((startOfDay(start).getTime() - startOfDay(reference).getTime()) / 86400000)
    var range = clockLabel(start) + "–" + clockLabel(due)
    if (startDelta === 0) return range
    if (startDelta === 1) return "Tmw " + range
    if (startDelta === -1) return "Yst " + range
    if (startDelta < 0) return Math.abs(startDelta) + "d late"
    return startDelta + "d " + range
  }

  var clock = clockLabel(due)
  if (dayDelta === 0) return clock
  if (dayDelta === 1) return "Tmw " + clock
  if (dayDelta === -1) return "Yst " + clock
  if (dayDelta < 0) return Math.abs(dayDelta) + "d late"
  return dayDelta + "d " + clock
}

function clockLabel(date) {
  return pad2(date.getHours()) + ":" + pad2(date.getMinutes())
}

function pad2(value) {
  return value < 10 ? "0" + value : String(value)
}

// ---- task details ------------------------------------------------------

// A task carries its long form in `content` and its checklist in `items`.
// Both are optional, so the row's affordance (and the key that opens it)
// should only exist when there is something behind them.
function hasDetails(task) {
  if (!task) return false
  if (String(task.content || "").trim() !== "") return true
  return subtasks(task).length > 0
}

// TickTick keeps every subtask ever typed in `items`, including ones whose
// title was later cleared. Those would render as a checkbox with no name,
// so they are filtered here — the one place every reader and counter
// shares. Status 0 is open; anything else TickTick has used means done.
function subtasks(task) {
  var items = (task && task.items) || []
  var result = []
  for (var i = 0; i < items.length; i++) {
    var title = String((items[i] && items[i].title) || "").trim()
    if (title === "") continue
    result.push({
      id: String(items[i].id || ""),
      title: title,
      done: Number(items[i].status || 0) !== 0
    })
  }
  return result
}

// The task as a standalone markdown note: heading, one line of metadata,
// the description verbatim, then the checklist. Shaped for handing a task
// to somewhere that has never heard of TickTick.
function taskMarkdown(task, projects, inboxId, now) {
  if (!task) return ""
  var lines = ["# " + plainText(String(task.title || "Untitled"))]

  var meta = []
  var project = projectName(projects, task.projectId, inboxId)
  if (project) meta.push(project)
  var names = task.tags || []
  for (var i = 0; i < names.length; i++) meta.push("#" + String(names[i]))
  var rank = priorityRank(task)
  if (rank !== "none") meta.push(rank + " priority")
  var due = dueLabel(task, now)
  if (due !== "") meta.push("due " + due)
  if (meta.length > 0) lines.push("", meta.join(" · "))

  var content = String(task.content || "").trim()
  if (content !== "") lines.push("", content)

  var items = subtasks(task)
  if (items.length > 0) {
    lines.push("")
    for (var j = 0; j < items.length; j++) {
      lines.push((items[j].done ? "- [x] " : "- [ ] ") + plainText(items[j].title))
    }
  }

  return lines.join("\n") + "\n"
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

// ---- sync interval -----------------------------------------------------

// Labels rather than a number field. A free-form seconds box invites values
// that are either pointless or rude to the API: tasks do not change
// second-to-second, and every tick costs five requests per bar.
var SYNC_INTERVALS = {
  "2 minutes": 120,
  "5 minutes": 300,
  "15 minutes": 900,
  "1 hour": 3600,
  "Only when opened": 0
}

function syncIntervalSeconds(label) {
  var seconds = SYNC_INTERVALS[String(label)]
  return seconds === undefined ? 300 : seconds
}

function syncIntervalLabels() {
  return ["2 minutes", "5 minutes", "15 minutes", "1 hour", "Only when opened"]
}

// ---- quick add ---------------------------------------------------------

// Inline syntax for the quick-add field. `#tag` and plain date words are
// TickTick's own conventions, so they behave the way its apps taught you.
// `!` for priority is this plugin's: TickTick has no quick-add symbol for
// it, so nothing is being contradicted by inventing one. A trailing clock
// time ("21:00", "9pm", "today 21:00-22:30") sets when — a range becomes a
// duration, a lone time becomes a due hour.
var PRIORITY_WORDS = {
  "1": 5, "high": 5, "h": 5,
  "2": 3, "medium": 3, "med": 3, "m": 3,
  "3": 1, "low": 1, "l": 1,
  "0": 0, "none": 0
}

var DATE_WORD = "(today|tomorrow|yesterday|\\d{4}-\\d{2}-\\d{2})"
// A bare "9" is deliberately not a time — a title can end with a number.
// An hour must carry a colon ("21:00", "9:30am") or a meridiem ("9pm").
var TIME_WORD = "(\\d{1,2}:\\d{2}(?:am|pm)?|\\d{1,2}(?:am|pm))"
var TIME_RANGE = TIME_WORD + "(?:\\s*-\\s*" + TIME_WORD + ")?"
var LEAD = "\\s(?:for\\s+|on\\s+|due\\s+|by\\s+)?"

// "9pm" → "21:00", "9:30am" → "09:30". Anything that is not a real clock
// returns null, and the token stays in the title rather than being eaten.
function toClock24(token) {
  var text = String(token).toLowerCase()

  var clock = text.match(/^(\d{1,2}):(\d{2})(am|pm)?$/)
  if (clock) {
    var hour = Number(clock[1])
    var minute = Number(clock[2])
    if (clock[3] === "pm" && hour < 12) hour += 12
    if (clock[3] === "am" && hour === 12) hour = 0
    if (hour > 23 || minute > 59) return null
    return pad2(hour) + ":" + pad2(minute)
  }

  var meridiem = text.match(/^(\d{1,2})(am|pm)$/)
  if (!meridiem) return null
  var hour12 = Number(meridiem[1])
  if (hour12 < 1 || hour12 > 12) return null
  if (meridiem[2] === "pm" && hour12 < 12) hour12 += 12
  if (meridiem[2] === "am" && hour12 === 12) hour12 = 0
  return pad2(hour12) + ":00"
}

// "a:b" → minutes. The CLI rebuilds instants from these, so they stay plain.
function clockMinutes(clock) {
  var parts = String(clock).split(":")
  return Number(parts[0]) * 60 + Number(parts[1])
}

function parseQuickAdd(text) {
  var rest = String(text || "")
  var tags = []
  var priority = 0
  var due = "today"
  var dueGiven = false
  var time = null

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

  // Only a trailing date/time blob is treated as one. "Call mum today" sets
  // a date; "Plan today's standup" keeps its word. The preposition goes
  // with the date — without that, "notes for today" becomes a task called
  // "notes for".
  var dateToken = null
  var startClock = null
  var endClock = null
  var endGiven = false

  var dateAndTime = rest.match(new RegExp(LEAD + DATE_WORD + "\\s+" + TIME_RANGE + "\\s*$", "i"))
  var dateOnly = dateAndTime ? null : rest.match(new RegExp(LEAD + DATE_WORD + "\\s*$", "i"))
  var timeOnly = dateAndTime || dateOnly ? null : rest.match(new RegExp(LEAD + TIME_RANGE + "\\s*$", "i"))

  if (dateAndTime) {
    dateToken = dateAndTime[1].toLowerCase()
    startClock = toClock24(dateAndTime[2])
    if (dateAndTime[3]) {
      endGiven = true
      endClock = toClock24(dateAndTime[3])
    }
  } else if (dateOnly) {
    dateToken = dateOnly[1].toLowerCase()
  } else if (timeOnly) {
    startClock = toClock24(timeOnly[1])
    if (timeOnly[2]) {
      endGiven = true
      endClock = toClock24(timeOnly[2])
    }
  }

  // A clock that is not a clock — "25:00", "9-10" with no colon — is just a
  // word. The whole trailing blob stays in the title and nothing is set,
  // which is also what keeps a title like "Finish 3" out of the parser.
  if (dateAndTime && (startClock === null || (endGiven && endClock === null))) {
    dateToken = null
    startClock = null
    endClock = null
  }
  if (timeOnly && (startClock === null || (endGiven && endClock === null))) {
    startClock = null
    endClock = null
  }

  var matched = dateAndTime || dateOnly || timeOnly
  if (matched && (dateToken !== null || startClock !== null)) {
    if (dateToken !== null) due = dateToken
    time = startClock === null ? null : (endClock !== null ? startClock + "-" + endClock : startClock)
    dueGiven = true
    rest = rest.slice(0, matched.index)
  }

  return {
    title: rest.replace(/\s+/g, " ").trim(),
    tags: tags,
    priority: priority,
    due: due,
    dueGiven: dueGiven,
    time: time
  }
}

// The inverse: render a task back into the line that would have produced it,
// so editing is the same grammar as adding rather than a second syntax to
// learn. A duration comes back as a range — which is what keeps one alive
// across an edit: the field pre-fills with the times, and whatever the line
// then says is what the task becomes.
function editLineFor(task, index) {
  if (!task) return ""
  var parts = [String(task.title || "")]

  var names = (task.tags || [])
  for (var i = 0; i < names.length; i++) parts.push("#" + String(names[i]))

  var rank = priorityRank(task)
  if (rank === "high") parts.push("!1")
  else if (rank === "medium") parts.push("!2")
  else if (rank === "low") parts.push("!3")

  var due = taskDueDate(task)
  if (due) {
    var start = taskStartDate(task)
    var anchor = start || due
    var delta = Math.round((startOfDay(anchor).getTime() - startOfDay(new Date()).getTime()) / 86400000)
    var tail = delta === 0 ? "today"
      : delta === 1 ? "tomorrow"
      : delta === -1 ? "yesterday"
      : anchor.getFullYear() + "-" + pad2(anchor.getMonth() + 1) + "-" + pad2(anchor.getDate())
    if (!task.isAllDay) {
      tail += " " + (start
        ? clockLabel(start) + "-" + clockLabel(due)
        : clockLabel(due))
    }
    parts.push(tail)
  }

  return parts.join(" ")
}

// What the line means as an edit. Tags, priority, and the schedule are
// always sent, because deleting "#work" (or the clock) from the line is how
// a tag (or a duration) is removed; an undated, untimed line sends neither.
function editArgs(taskId, text) {
  var parsed = parseQuickAdd(text)
  if (parsed.title === "") return null
  var args = [
    "update", String(taskId),
    "--title", parsed.title,
    "--priority", String(parsed.priority),
    "--tags", parsed.tags.join(",")
  ]
  if (parsed.dueGiven) args = args.concat(["--due", parsed.due])
  if (parsed.time) args = args.concat(["--time", parsed.time])
  return args
}

function quickAddArgs(text) {
  var parsed = parseQuickAdd(text)
  if (parsed.title === "") return null
  var args = ["add", parsed.title, "--due", parsed.due]
  if (parsed.time) args = args.concat(["--time", parsed.time])
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

var BAR_LABEL_MODES = ["Count", "Next", "Icon"]

function cycleBarLabel(current) {
  var i = BAR_LABEL_MODES.indexOf(String(current))
  if (i < 0) i = 0
  return BAR_LABEL_MODES[(i + 1) % BAR_LABEL_MODES.length]
}

function barLabelDescription(mode) {
  if (mode === "Next") return "next task"
  if (mode === "Icon") return "icon only"
  return "counts"
}

function barLabel(mode, tasks, habitsLeft, now) {
  if (mode === "Icon") return ""

  if (mode === "Next") {
    var next = nextTask(tasks)
    if (!next) return habitsLeft > 0 ? habitsLeft + " habits" : ""
    // This string ends up in the shell's own Text items (WidgetButton,
    // OpticalGlyph), which default to AutoText — sanitized, not just elided.
    return elide(plainText(next.title), 28)
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

// For remote strings headed into Text items outside this plugin, where
// textFormat cannot be pinned to PlainText. Qt's AutoText heuristic keys on
// angle brackets, so swapping them for lookalikes keeps a title readable
// while making it inert.
function plainText(text) {
  return String(text || "").replace(/</g, "‹").replace(/>/g, "›")
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

// Held actions are a stack, not a single slot. Ticking four things off in a
// row is the normal way a list gets cleared, and holding only the newest
// meant the previous three were already gone by the time anyone noticed the
// mistake — the undo window failed exactly where mistakes cluster.
//
// Splitting the due ones from the rest is pure list work, so it lives here
// where it can be tested rather than inside a timer.
function expirePending(list, nowMs) {
  var now = nowMs || Date.now()
  var due = []
  var remaining = []
  for (var i = 0; i < (list || []).length; i++) {
    var entry = list[i]
    if (entry && entry.deadline <= now) due.push(entry)
    else remaining.push(entry)
  }
  return { due: due, remaining: remaining }
}

// What `u` would undo: the most recent, since that is the one just done.
function topPending(list) {
  return (list && list.length > 0) ? list[list.length - 1] : null
}

function dropTopPending(list) {
  return (list && list.length > 0) ? list.slice(0, list.length - 1) : []
}

// The countdown is rendered separately, so this is only the sentence part.
function undoLabel(pending, secondsLeft) {
  if (!pending) return ""
  var name = elide(String(pending.title || ""), 26)
  var verb = pending.kind === "checkin" ? "Checked in" : "Completed"
  return verb + " " + name
}

// Says how much is waiting behind the one being offered for undo, so a stack
// of held actions is never invisible.
function heldSuffix(count) {
  return count > 1 ? "  +" + (count - 1) + " more" : ""
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
    taskStartDate: taskStartDate,
    taskTimeKey: taskTimeKey,
    startOfDay: startOfDay,
    endOfDay: endOfDay,
    addDays: addDays,
    dateStamp: dateStamp,
    stampToDate: stampToDate,
    horizonDays: horizonDays,
    cycleHorizon: cycleHorizon,
    horizons: horizons,
    horizonIndex: horizonIndex,
    horizonForDue: horizonForDue,
    widerHorizon: widerHorizon,
    isOpen: isOpen,
    isOverdue: isOverdue,
    dueTasks: dueTasks,
    nextTask: nextTask,
    nextTaskTitle: nextTaskTitle,
    dueLabel: dueLabel,
    priorityRank: priorityRank,
    tagIndex: tagIndex,
    firstTag: firstTag,
    tagColor: tagColor,
    tagLabel: tagLabel,
    dueTier: dueTier,
    syncIntervalSeconds: syncIntervalSeconds,
    syncIntervalLabels: syncIntervalLabels,
    parseQuickAdd: parseQuickAdd,
    quickAddArgs: quickAddArgs,
    editLineFor: editLineFor,
    editArgs: editArgs,
    projectName: projectName,
    checkinFor: checkinFor,
    habitProgress: habitProgress,
    habitStreak: habitStreak,
    habitLabel: habitLabel,
    habitsRemaining: habitsRemaining,
    barLabel: barLabel,
    plainText: plainText,
    hasDetails: hasDetails,
    subtasks: subtasks,
    taskMarkdown: taskMarkdown,
    cycleBarLabel: cycleBarLabel,
    barLabelDescription: barLabelDescription,
    elide: elide,
    overdueCount: overdueCount,
    formatClock: formatClock,
    pomoPhaseAfter: pomoPhaseAfter,
    mergePomoPrefs: mergePomoPrefs,
    pomoPhaseSeconds: pomoPhaseSeconds,
    pomoPhaseLabel: pomoPhaseLabel,
    pomoTodayLabel: pomoTodayLabel,
    undoSecondsLeft: undoSecondsLeft,
    expirePending: expirePending,
    topPending: topPending,
    dropTopPending: dropTopPending,
    heldSuffix: heldSuffix,
    undoLabel: undoLabel,
    parseCache: parseCache,
    staleMinutes: staleMinutes
  }
}

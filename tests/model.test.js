const test = require('node:test')
const assert = require('node:assert')
const Model = require('../Model.js')

const NOW = new Date(2026, 7, 12, 14, 0, 0) // 2026-08-12 14:00 local

// A timestamp 5h before NOW — "this morning" in every timezone the tests
// run in. A hardcoded offset here only passes for zones west of UTC-4.
const MORNING_ISO = new Date(NOW.getTime() - 5 * 3600 * 1000)
  .toISOString().replace('Z', '+0000')

function task(over) {
  return Object.assign({
    id: 'x',
    projectId: 'p1',
    title: 'Thing',
    status: 0,
    priority: 0,
    isAllDay: true,
    sortOrder: 0
  }, over)
}

// Duration tasks carry their start and end in the "+0000" shape TickTick
// sends. Built from local Dates the same way MORNING_ISO is, so the tests
// stay honest in every timezone.
function iso(local) {
  return local.toISOString().replace('Z', '+0000')
}

function span(startLocal, dueLocal, over) {
  return task(Object.assign({
    isAllDay: false,
    startDate: iso(startLocal),
    dueDate: iso(dueLocal)
  }, over))
}

// --- dates ---------------------------------------------------------------

test('parseApiDate handles the +0000 offset TickTick sends', () => {
  const parsed = Model.parseApiDate('2026-08-12T04:00:00.000+0000')
  assert.equal(parsed.getTime(), Date.UTC(2026, 7, 12, 4, 0, 0))
})

test('parseApiDate returns null on junk', () => {
  assert.equal(Model.parseApiDate(''), null)
  assert.equal(Model.parseApiDate('not a date'), null)
})

test('an all-day due date keeps its calendar day regardless of local zone', () => {
  // UTC midnight would land on the 11th anywhere west of Greenwich if this
  // were parsed as an instant instead of a calendar date.
  const due = Model.taskDueDate(task({ dueDate: '2026-08-12T00:00:00.000+0000' }))
  assert.equal(due.getFullYear(), 2026)
  assert.equal(due.getMonth(), 7)
  assert.equal(due.getDate(), 12)
})

test('a timed due date is parsed as an instant', () => {
  const due = Model.taskDueDate(task({ isAllDay: false, dueDate: '2026-08-12T18:30:00.000+0000' }))
  assert.equal(due.getTime(), Date.UTC(2026, 7, 12, 18, 30, 0))
})

// --- task selection ------------------------------------------------------

test('dueTasks keeps today and drops later days on the Today horizon', () => {
  const tasks = [
    task({ id: 'today', dueDate: '2026-08-12T00:00:00.000+0000' }),
    task({ id: 'later', dueDate: '2026-08-20T00:00:00.000+0000' })
  ]
  const due = Model.dueTasks(tasks, { now: NOW, horizon: 'Today' })
  assert.deepEqual(due.map(t => t.id), ['today'])
})

test('the Next 7 days horizon reaches a week out but not past it', () => {
  const tasks = [
    task({ id: 'in6', dueDate: '2026-08-18T00:00:00.000+0000' }),
    task({ id: 'in9', dueDate: '2026-08-21T00:00:00.000+0000' })
  ]
  const due = Model.dueTasks(tasks, { now: NOW, horizon: 'Next 7 days' })
  assert.deepEqual(due.map(t => t.id), ['in6'])
})

test('overdue tasks sort ahead of everything due today', () => {
  const tasks = [
    task({ id: 'today', dueDate: '2026-08-12T00:00:00.000+0000' }),
    task({ id: 'late', dueDate: '2026-08-09T00:00:00.000+0000' })
  ]
  const due = Model.dueTasks(tasks, { now: NOW, horizon: 'Today' })
  assert.deepEqual(due.map(t => t.id), ['late', 'today'])
})

test('includeOverdue false hides the backlog', () => {
  const tasks = [
    task({ id: 'today', dueDate: '2026-08-12T00:00:00.000+0000' }),
    task({ id: 'late', dueDate: '2026-08-09T00:00:00.000+0000' })
  ]
  const due = Model.dueTasks(tasks, { now: NOW, horizon: 'Today', includeOverdue: false })
  assert.deepEqual(due.map(t => t.id), ['today'])
})

test('completed, abandoned, undated, and deleted tasks never show', () => {
  const tasks = [
    task({ id: 'done', status: 2, dueDate: '2026-08-12T00:00:00.000+0000' }),
    task({ id: 'wontdo', status: -1, dueDate: '2026-08-12T00:00:00.000+0000' }),
    task({ id: 'undated' }),
    task({ id: 'gone', deleted: 1, dueDate: '2026-08-12T00:00:00.000+0000' })
  ]
  assert.deepEqual(Model.dueTasks(tasks, { now: NOW }), [])
})

test('same-day ties break on priority, high first', () => {
  const tasks = [
    task({ id: 'low', priority: 1, dueDate: '2026-08-12T00:00:00.000+0000' }),
    task({ id: 'high', priority: 5, dueDate: '2026-08-12T00:00:00.000+0000' })
  ]
  const due = Model.dueTasks(tasks, { now: NOW })
  assert.deepEqual(due.map(t => t.id), ['high', 'low'])
})

test('an all-day task due today is not overdue at 2pm', () => {
  assert.equal(Model.isOverdue(task({ dueDate: '2026-08-12T00:00:00.000+0000' }), NOW), false)
})

test('a timed task from this morning is overdue at 2pm', () => {
  const morning = task({ isAllDay: false, dueDate: MORNING_ISO })
  assert.equal(Model.isOverdue(morning, NOW), true)
})

// --- labels --------------------------------------------------------------

test('dueLabel names the near days and counts the far ones', () => {
  assert.equal(Model.dueLabel(task({ dueDate: '2026-08-12T00:00:00.000+0000' }), NOW), 'Today')
  assert.equal(Model.dueLabel(task({ dueDate: '2026-08-13T00:00:00.000+0000' }), NOW), 'Tomorrow')
  assert.equal(Model.dueLabel(task({ dueDate: '2026-08-11T00:00:00.000+0000' }), NOW), 'Yesterday')
  assert.equal(Model.dueLabel(task({ dueDate: '2026-08-08T00:00:00.000+0000' }), NOW), '4d late')
  assert.equal(Model.dueLabel(task({ dueDate: '2026-08-15T00:00:00.000+0000' }), NOW), '3d')
})

// --- durations -----------------------------------------------------------

test('a duration task shows its start–end range, not the end time', () => {
  // TickTick stores "Meeting 8:30–9:30" as startDate 8:30 with dueDate 9:30,
  // so the row that used to read 09:30 now reads the whole block.
  const meeting = span(new Date(2026, 7, 12, 8, 30), new Date(2026, 7, 12, 9, 30))
  assert.equal(Model.dueLabel(meeting, NOW), '08:30–09:30')
})

test('a duration crossing midnight keys the day off its start', () => {
  const late = span(new Date(2026, 7, 12, 23, 30), new Date(2026, 7, 13, 0, 30))
  assert.equal(Model.dueLabel(late, NOW), '23:30–00:30')
})

test('duration ranges carry the same day markers as plain times', () => {
  assert.equal(Model.dueLabel(span(new Date(2026, 7, 13, 8, 30), new Date(2026, 7, 13, 9, 30)), NOW), 'Tmw 08:30–09:30')
  assert.equal(Model.dueLabel(span(new Date(2026, 7, 11, 8, 30), new Date(2026, 7, 11, 9, 30)), NOW), 'Yst 08:30–09:30')
  assert.equal(Model.dueLabel(span(new Date(2026, 7, 15, 8, 30), new Date(2026, 7, 15, 9, 30)), NOW), '3d 08:30–09:30')
  assert.equal(Model.dueLabel(span(new Date(2026, 7, 10, 8, 30), new Date(2026, 7, 10, 9, 30)), NOW), '2d late')
})

test('only a start earlier than the end counts as a duration', () => {
  const at = iso(new Date(2026, 7, 12, 9, 30))
  // An ordinary timed task carries the same instant in both fields.
  assert.equal(Model.taskStartDate(task({ isAllDay: false, startDate: at, dueDate: at })), null)
  assert.equal(Model.taskStartDate(task({ isAllDay: false, startDate: null, dueDate: at })), null)
  assert.equal(Model.taskStartDate(
    task({ isAllDay: true, startDate: at, dueDate: iso(new Date(2026, 7, 12, 10, 30)) })), null)
  assert.equal(Model.taskStartDate(span(new Date(2026, 7, 12, 8, 30), new Date(2026, 7, 12, 9, 30))).getTime(),
    new Date(2026, 7, 12, 8, 30).getTime())
})

test('a plain timed task keeps its single due time', () => {
  const at = iso(new Date(2026, 7, 12, 9, 30))
  const plain = task({ isAllDay: false, startDate: at, dueDate: at })
  assert.equal(Model.dueLabel(plain, NOW), '09:30')
})

test('an all-day multi-day span still counts to its last day', () => {
  const trip = task({
    isAllDay: true,
    startDate: '2026-08-11T00:00:00.000+0000',
    dueDate: '2026-08-15T00:00:00.000+0000'
  })
  assert.equal(Model.dueLabel(trip, NOW), '3d')
})

test('a duration task is ordered by when it starts', () => {
  // Sorted by end time the 16:00 report would outrank the meeting; by start
  // the meeting goes first, which is when it actually lands in the day.
  const meeting = span(new Date(2026, 7, 12, 15, 30), new Date(2026, 7, 12, 16, 30), { id: 'meeting' })
  const report = task({
    id: 'report',
    isAllDay: false,
    startDate: iso(new Date(2026, 7, 12, 16, 0)),
    dueDate: iso(new Date(2026, 7, 12, 16, 0))
  })
  const due = Model.dueTasks([report, meeting], { now: NOW, horizon: 'Today' })
  assert.deepEqual(due.map(t => t.id), ['meeting', 'report'])
})

test('a duration starting late today stays in Today despite its after-midnight end', () => {
  const late = span(new Date(2026, 7, 12, 23, 30), new Date(2026, 7, 13, 0, 30), { id: 'late' })
  const due = Model.dueTasks([late], { now: NOW, horizon: 'Today' })
  assert.deepEqual(due.map(t => t.id), ['late'])
})

test('a duration task ranks ahead of plain dated tasks', () => {
  // The all-day task's time key is midnight, so by time alone it would
  // always outrank an evening block — the meeting would drown under every
  // floating task dated today.
  const meeting = span(new Date(2026, 7, 12, 21, 0), new Date(2026, 7, 12, 22, 30), { id: 'meeting' })
  const float = task({ id: 'float', dueDate: '2026-08-12T00:00:00.000+0000' })
  const due = Model.dueTasks([float, meeting], { now: NOW, horizon: 'Today' })
  assert.deepEqual(due.map(t => t.id), ['meeting', 'float'])
})

test('late work still outranks a duration task that has not started', () => {
  const overdue = task({ id: 'overdue', dueDate: '2026-08-09T00:00:00.000+0000' })
  const meeting = span(new Date(2026, 7, 12, 21, 0), new Date(2026, 7, 12, 22, 30), { id: 'meeting' })
  const due = Model.dueTasks([meeting, overdue], { now: NOW, horizon: 'Today' })
  assert.deepEqual(due.map(t => t.id), ['overdue', 'meeting'])
})

// --- task details --------------------------------------------------------

test('hasDetails is true for a description or a named subtask, and false for empties', () => {
  assert.equal(Model.hasDetails({ content: '  \n' }), false)
  assert.equal(Model.hasDetails({ items: [{ title: '' }, { title: '  ' }] }), false)
  assert.equal(Model.hasDetails({}), false)
  assert.equal(Model.hasDetails(null), false)
  assert.equal(Model.hasDetails({ content: 'notes' }), true)
  assert.equal(Model.hasDetails({ items: [{ title: 'step', status: 0 }] }), true)
})

test('subtasks drop unnamed items and map status to done', () => {
  // "Projecto astro" carries a subtask whose title was cleared; it would
  // render as a checkbox with no name and be counted in "0/2".
  const items = Model.subtasks({
    items: [
      { id: 'a', title: ' first ', status: 0 },
      { id: 'b', title: '', status: 1 },
      { id: 'c', title: 'done one', status: 1 },
      { title: 'no id', status: 2 }
    ]
  })
  assert.deepEqual(items, [
    { id: 'a', title: 'first', done: false },
    { id: 'c', title: 'done one', done: true },
    { id: '', title: 'no id', done: true }
  ])
})

test('taskMarkdown renders a document: heading, metadata, description, checklist', () => {
  const projects = [{ id: 'p1', name: 'Boletokk' }]
  const md = Model.taskMarkdown({
    title: 'Ship <it>',
    projectId: 'p1',
    tags: ['work'],
    priority: 5,
    isAllDay: false,
    startDate: iso(new Date(2026, 7, 12, 8, 30)),
    dueDate: iso(new Date(2026, 7, 12, 9, 30)),
    content: 'Body with **bold**.\n\nSecond line.',
    items: [
      { id: 'a', title: 'first', status: 1 },
      { id: 'b', title: 'second', status: 0 },
      { id: 'c', title: '', status: 0 }
    ]
  }, projects, 'inbox1', NOW)
  assert.equal(md, [
    '# Ship ‹it›',
    '',
    'Boletokk · #work · high priority · due 08:30–09:30',
    '',
    'Body with **bold**.',
    '',
    'Second line.',
    '',
    '- [x] first',
    '- [ ] second',
    ''
  ].join('\n'))
})

test('a bare task is a heading and one metadata line', () => {
  const md = Model.taskMarkdown(
    task({ title: 'Thing', dueDate: '2026-08-12T00:00:00.000+0000' }), [], 'inbox1', NOW)
  assert.equal(md, '# Thing\n\ndue Today\n')
})

test('taskMarkdown tolerates a missing task', () => {
  assert.equal(Model.taskMarkdown(null, [], '', NOW), '')
})

test('priorityRank maps TickTick 0/1/3/5', () => {
  assert.equal(Model.priorityRank(task({ priority: 0 })), 'none')
  assert.equal(Model.priorityRank(task({ priority: 1 })), 'low')
  assert.equal(Model.priorityRank(task({ priority: 3 })), 'medium')
  assert.equal(Model.priorityRank(task({ priority: 5 })), 'high')
})

test('barLabel counts tasks and open habits, and stays empty when idle', () => {
  const tasks = [task({ id: 'a' }), task({ id: 'b' })]
  assert.equal(Model.barLabel('Count', tasks, 3, NOW), '2  3♦')
  assert.equal(Model.barLabel('Count', [], 0, NOW), '')
  assert.equal(Model.barLabel('Icon', tasks, 3, NOW), '')
  assert.equal(Model.barLabel('Next', tasks, 0, NOW), 'Thing')
})

test('barLabel elides a long next title', () => {
  const long = task({ title: 'Rewrite the entire authentication middleware today' })
  assert.equal(Model.barLabel('Next', [long], 0, NOW).length, 28)
})

test('the Next label defangs HTML-shaped titles before the shell sees them', () => {
  const hostile = task({ title: '<img src="x"> <b>bold</b>' })
  const label = Model.barLabel('Next', [hostile], 0, NOW)
  assert.ok(!label.includes('<') && !label.includes('>'), label)
})

test('plainText swaps angle brackets for lookalikes and tolerates junk', () => {
  assert.equal(Model.plainText('<i>x</i>'), '‹i›x‹/i›')
  assert.equal(Model.plainText(null), '')
  assert.equal(Model.plainText('plain'), 'plain')
})

// --- habits --------------------------------------------------------------

const HABIT = { id: 'h1', name: 'Read', goal: 1, type: 'Boolean' }
const QUANTIFIED = { id: 'h2', name: 'Water', goal: 8, step: 1, unit: 'cups', type: 'Real' }

test('habitProgress reports an unchecked day as not done', () => {
  const progress = Model.habitProgress(HABIT, {}, 20260812)
  assert.equal(progress.done, false)
  assert.equal(progress.ratio, 0)
})

test('habitProgress reads a completed check-in', () => {
  const checkins = { h1: [{ checkinStamp: 20260812, status: 2, value: 1 }] }
  assert.equal(Model.habitProgress(HABIT, checkins, 20260812).done, true)
})

test('a quantified habit reports a partial ratio', () => {
  const checkins = { h2: [{ checkinStamp: 20260812, status: 0, value: 2 }] }
  const progress = Model.habitProgress(QUANTIFIED, checkins, 20260812)
  assert.equal(progress.ratio, 0.25)
  assert.equal(progress.done, false)
  assert.equal(progress.quantified, true)
})

test('habitLabel shows the tally only for quantified habits', () => {
  const bare = Model.habitProgress(HABIT, {}, 20260812)
  assert.equal(Model.habitLabel(HABIT, bare), 'Read')

  const checkins = { h2: [{ checkinStamp: 20260812, status: 0, value: 2 }] }
  const partial = Model.habitProgress(QUANTIFIED, checkins, 20260812)
  assert.equal(Model.habitLabel(QUANTIFIED, partial), 'Water  2/8 cups')
})

test('habitStreak counts consecutive completed days ending today', () => {
  const checkins = {
    h1: [
      { checkinStamp: 20260810, status: 2 },
      { checkinStamp: 20260811, status: 2 },
      { checkinStamp: 20260812, status: 2 }
    ]
  }
  assert.equal(Model.habitStreak(checkins, 'h1', 20260812), 3)
})

test('a streak survives a today that is still open', () => {
  const checkins = {
    h1: [
      { checkinStamp: 20260810, status: 2 },
      { checkinStamp: 20260811, status: 2 }
    ]
  }
  assert.equal(Model.habitStreak(checkins, 'h1', 20260812), 2)
})

test('a gap ends the streak', () => {
  const checkins = {
    h1: [
      { checkinStamp: 20260808, status: 2 },
      { checkinStamp: 20260810, status: 2 },
      { checkinStamp: 20260811, status: 2 }
    ]
  }
  assert.equal(Model.habitStreak(checkins, 'h1', 20260812), 2)
})

test('a failed day does not count toward a streak', () => {
  const checkins = { h1: [{ checkinStamp: 20260811, status: 1 }] }
  assert.equal(Model.habitStreak(checkins, 'h1', 20260812), 0)
})

test('habitsRemaining counts only the unchecked', () => {
  const checkins = { h1: [{ checkinStamp: 20260812, status: 2, value: 1 }] }
  assert.equal(Model.habitsRemaining([HABIT, QUANTIFIED], checkins, 20260812), 1)
})

// --- cache ---------------------------------------------------------------

test('parseCache survives an empty, truncated, or non-object file', () => {
  for (const input of ['', '{"tasks":', 'null', '[]']) {
    const cache = Model.parseCache(input)
    assert.deepEqual(cache.tasks, [])
    assert.deepEqual(cache.habits, [])
    assert.equal(cache.authRequired, false)
  }
})

test('parseCache carries the auth flag and error through', () => {
  const cache = Model.parseCache(JSON.stringify({ authRequired: true, error: 'nope', tasks: [task({})] }))
  assert.equal(cache.authRequired, true)
  assert.equal(cache.error, 'nope')
  assert.equal(cache.tasks.length, 1)
})

test('staleMinutes reports -1 when nothing has ever synced', () => {
  assert.equal(Model.staleMinutes(0, Date.now()), -1)
  assert.equal(Model.staleMinutes(Date.now() - 5 * 60000, Date.now()), 5)
})

// --- pomodoro ------------------------------------------------------------

const PREFS = { pomoDuration: 50, shortBreakDuration: 10, longBreakDuration: 30, longBreakInterval: 4, pomoGoal: 4 }

test('formatClock pads minutes and seconds, and grows an hour field', () => {
  assert.equal(Model.formatClock(0), '00:00')
  assert.equal(Model.formatClock(65), '01:05')
  assert.equal(Model.formatClock(1505), '25:05')
  assert.equal(Model.formatClock(3661), '1:01:01')
})

test('formatClock never renders a negative clock', () => {
  assert.equal(Model.formatClock(-30), '00:00')
})

test('the long break lands on the configured interval, not before', () => {
  assert.equal(Model.pomoPhaseAfter(1, PREFS), 'shortBreak')
  assert.equal(Model.pomoPhaseAfter(3, PREFS), 'shortBreak')
  assert.equal(Model.pomoPhaseAfter(4, PREFS), 'longBreak')
  assert.equal(Model.pomoPhaseAfter(8, PREFS), 'longBreak')
})

test('phase durations come from the account settings, in seconds', () => {
  assert.equal(Model.pomoPhaseSeconds('focus', PREFS), 3000)
  assert.equal(Model.pomoPhaseSeconds('shortBreak', PREFS), 600)
  assert.equal(Model.pomoPhaseSeconds('longBreak', PREFS), 1800)
})

test('phase durations fall back sanely when settings are missing', () => {
  assert.equal(Model.pomoPhaseSeconds('focus', {}), 1500)
  assert.equal(Model.pomoPhaseSeconds('focus', null), 1500)
})

test('pomoTodayLabel shows progress against the goal', () => {
  assert.equal(Model.pomoTodayLabel({ todayPomoCount: 2, todayPomoDuration: 100 }, PREFS), '2/4 today · 100m')
  assert.equal(Model.pomoTodayLabel({ todayPomoCount: 0, todayPomoDuration: 0 }, PREFS), '0/4 today')
  assert.equal(Model.pomoTodayLabel({}, {}), '0 today')
})

// --- undo window ---------------------------------------------------------

test('undoSecondsLeft counts down and floors at zero', () => {
  const now = 1_000_000
  assert.equal(Model.undoSecondsLeft(now + 6000, now), 6)
  assert.equal(Model.undoSecondsLeft(now + 1, now), 1)
  assert.equal(Model.undoSecondsLeft(now - 5000, now), 0)
  assert.equal(Model.undoSecondsLeft(0, now), 0)
})

test('undoLabel names the action and elides a long title', () => {
  // The countdown is drawn as its own element so it can never be the part
  // that gets truncated.
  assert.equal(Model.undoLabel({ kind: 'complete', title: 'Pay rent' }, 5), 'Completed Pay rent')
  assert.equal(Model.undoLabel({ kind: 'checkin', title: 'Read' }, 3), 'Checked in Read')
  assert.ok(Model.undoLabel({ kind: 'complete', title: 'x'.repeat(80) }, 2).length < 45)
})

test('undoLabel tolerates no pending action', () => {
  assert.equal(Model.undoLabel(null, 5), '')
})

test('parseCache defaults the pomodoro keys', () => {
  const cache = Model.parseCache('')
  assert.deepEqual(cache.pomoStats, {})
  assert.deepEqual(cache.pomoPrefs, {})
})

// --- pomodoro overrides --------------------------------------------------

const ACCOUNT = { pomoDuration: 50, shortBreakDuration: 10, longBreakDuration: 30, longBreakInterval: 4, pomoGoal: 4 }

test('with no overrides the account settings are used as-is', () => {
  assert.deepEqual(Model.mergePomoPrefs(ACCOUNT, {}), ACCOUNT)
  assert.deepEqual(Model.mergePomoPrefs(ACCOUNT, null), ACCOUNT)
})

test('a non-zero override wins, and only for the field it sets', () => {
  const merged = Model.mergePomoPrefs(ACCOUNT, { pomoMinutes: 25 })
  assert.equal(merged.pomoDuration, 25)
  assert.equal(merged.shortBreakDuration, 10)
  assert.equal(merged.longBreakInterval, 4)
})

test('zero means follow the account, not zero minutes', () => {
  const merged = Model.mergePomoPrefs(ACCOUNT, { pomoMinutes: 0, longBreakInterval: 0 })
  assert.equal(merged.pomoDuration, 50)
  assert.equal(merged.longBreakInterval, 4)
})

test('every override can be set at once', () => {
  const merged = Model.mergePomoPrefs(ACCOUNT,
    { pomoMinutes: 30, shortBreakMinutes: 3, longBreakMinutes: 20, longBreakInterval: 3 })
  assert.equal(merged.pomoDuration, 30)
  assert.equal(merged.shortBreakDuration, 3)
  assert.equal(merged.longBreakDuration, 20)
  assert.equal(merged.longBreakInterval, 3)
})

test('with neither account nor override, sane pomodoro defaults appear', () => {
  const merged = Model.mergePomoPrefs({}, {})
  assert.equal(merged.pomoDuration, 25)
  assert.equal(merged.shortBreakDuration, 5)
  assert.equal(merged.longBreakDuration, 15)
  assert.equal(merged.longBreakInterval, 4)
})

test('overridden durations flow through to phase seconds and cycle', () => {
  const merged = Model.mergePomoPrefs(ACCOUNT, { pomoMinutes: 25, longBreakInterval: 2 })
  assert.equal(Model.pomoPhaseSeconds('focus', merged), 1500)
  assert.equal(Model.pomoPhaseAfter(2, merged), 'longBreak')
  assert.equal(Model.pomoPhaseAfter(1, merged), 'shortBreak')
})

// --- tags and due tiers --------------------------------------------------

const TAGS = [
  { name: 'book', label: 'Book', color: '#52B8D2' },
  { name: 'goal', label: 'GOAL', color: '#9842EB' },
  { name: 'nocolor', label: 'NoColor', color: null }
]
const IDX = Model.tagIndex(TAGS)

test('tagIndex keys on the lowercase name that tasks reference', () => {
  assert.equal(IDX['book'].label, 'Book')
  assert.equal(IDX['Book'], undefined)
})

test('a task takes the colour of its first resolvable tag', () => {
  assert.equal(Model.tagColor(task({ tags: ['book'] }), IDX), '#52B8D2')
  assert.equal(Model.tagLabel(task({ tags: ['book'] }), IDX), 'Book')
})

test('an unknown tag is skipped in favour of a known one', () => {
  assert.equal(Model.tagColor(task({ tags: ['ghost', 'goal'] }), IDX), '#9842EB')
})

test('untagged, unknown-only, and colourless tags yield no colour', () => {
  assert.equal(Model.tagColor(task({}), IDX), '')
  assert.equal(Model.tagColor(task({ tags: [] }), IDX), '')
  assert.equal(Model.tagColor(task({ tags: ['ghost'] }), IDX), '')
  assert.equal(Model.tagColor(task({ tags: ['nocolor'] }), IDX), '')
})

test('tagIndex tolerates junk', () => {
  assert.deepEqual(Model.tagIndex(null), {})
  assert.deepEqual(Model.tagIndex([null, {}, { name: 'a' }]), { a: { name: 'a' } })
})

test('dueTier separates overdue, today, and upcoming', () => {
  assert.equal(Model.dueTier(task({ dueDate: '2026-08-09T00:00:00.000+0000' }), NOW), 'overdue')
  assert.equal(Model.dueTier(task({ dueDate: '2026-08-12T00:00:00.000+0000' }), NOW), 'today')
  assert.equal(Model.dueTier(task({ dueDate: '2026-08-20T00:00:00.000+0000' }), NOW), 'upcoming')
})

test('an undated task is not treated as due today', () => {
  assert.equal(Model.dueTier(task({}), NOW), 'upcoming')
})

test('a timed task earlier today is overdue, not today', () => {
  assert.equal(
    Model.dueTier(task({ isAllDay: false, dueDate: MORNING_ISO }), NOW),
    'overdue')
})

test('parseCache defaults tags to an empty list', () => {
  assert.deepEqual(Model.parseCache('').tags, [])
})

// --- quick-add syntax ----------------------------------------------------

test('a bare title is due today with no tags or priority', () => {
  assert.deepEqual(Model.parseQuickAdd('Pay rent'),
    { title: 'Pay rent', tags: [], priority: 0, due: 'today', dueGiven: false, time: null })
})

test('# attaches tags and strips them from the title', () => {
  const parsed = Model.parseQuickAdd('Renew cert #work #ops')
  assert.equal(parsed.title, 'Renew cert')
  assert.deepEqual(parsed.tags, ['work', 'ops'])
})

test('tags are lowercased, since that is how tasks reference them', () => {
  assert.deepEqual(Model.parseQuickAdd('Read #Book').tags, ['book'])
})

test('! maps to TickTick priorities by number or word', () => {
  assert.equal(Model.parseQuickAdd('x !1').priority, 5)
  assert.equal(Model.parseQuickAdd('x !high').priority, 5)
  assert.equal(Model.parseQuickAdd('x !2').priority, 3)
  assert.equal(Model.parseQuickAdd('x !med').priority, 3)
  assert.equal(Model.parseQuickAdd('x !3').priority, 1)
  assert.equal(Model.parseQuickAdd('x !low').priority, 1)
})

test('an unrecognised ! token is left in the title', () => {
  const parsed = Model.parseQuickAdd('Ship !bogus now')
  assert.equal(parsed.title, 'Ship !bogus now')
  assert.equal(parsed.priority, 0)
})

test('a trailing date word sets the due date and leaves', () => {
  assert.deepEqual(Model.parseQuickAdd('Ship it tomorrow'),
    { title: 'Ship it', tags: [], priority: 0, due: 'tomorrow', dueGiven: true, time: null })
  assert.equal(Model.parseQuickAdd('Review 2026-09-01').due, '2026-09-01')
})

test('a preposition goes with the trailing date', () => {
  assert.equal(Model.parseQuickAdd('Standup notes for today').title, 'Standup notes')
  assert.equal(Model.parseQuickAdd('Ship by tomorrow').title, 'Ship')
  assert.equal(Model.parseQuickAdd('Review due 2026-09-01').title, 'Review')
})

test('a date word that is not trailing stays in the title', () => {
  assert.equal(Model.parseQuickAdd('Plan today standup').title, 'Plan today standup')
  assert.equal(Model.parseQuickAdd('Today matters').title, 'Today matters')
})

test('everything combines, in any order', () => {
  const parsed = Model.parseQuickAdd('Renew the TLS cert #work !1 tomorrow')
  assert.equal(parsed.title, 'Renew the TLS cert')
  assert.deepEqual(parsed.tags, ['work'])
  assert.equal(parsed.priority, 5)
  assert.equal(parsed.due, 'tomorrow')
})

test('whitespace is collapsed, not preserved', () => {
  assert.equal(Model.parseQuickAdd('  spaced   out  #tag  ').title, 'spaced out')
})

test('quickAddArgs omits flags that are not set', () => {
  assert.deepEqual(Model.quickAddArgs('Pay rent'), ['add', 'Pay rent', '--due', 'today'])
})

test('quickAddArgs passes tags and priority through', () => {
  assert.deepEqual(Model.quickAddArgs('Fix it #ops !1 tomorrow'),
    ['add', 'Fix it', '--due', 'tomorrow', '--priority', '5', '--tags', 'ops'])
})

test('quickAddArgs refuses input with no title left', () => {
  assert.equal(Model.quickAddArgs('   '), null)
  assert.equal(Model.quickAddArgs('#tag !1'), null)
})

// --- horizon switching ---------------------------------------------------

test('cycleHorizon walks forward and wraps', () => {
  assert.equal(Model.cycleHorizon('Today', 1), 'Tomorrow')
  assert.equal(Model.cycleHorizon('Tomorrow', 1), 'Next 7 days')
  assert.equal(Model.cycleHorizon('Next 7 days', 1), 'Today')
})

test('cycleHorizon walks backward and wraps', () => {
  assert.equal(Model.cycleHorizon('Today', -1), 'Next 7 days')
  assert.equal(Model.cycleHorizon('Next 7 days', -1), 'Tomorrow')
})

test('cycleHorizon recovers from an unknown value', () => {
  assert.equal(Model.cycleHorizon('nonsense', 1), 'Tomorrow')
})

test('horizonForDue names the narrowest view that shows the task', () => {
  const now = new Date(2026, 7, 13)
  assert.equal(Model.horizonForDue('today', now), 'Today')
  assert.equal(Model.horizonForDue('tomorrow', now), 'Tomorrow')
  assert.equal(Model.horizonForDue('2026-08-15', now), 'Next 7 days')
  assert.equal(Model.horizonForDue('2026-08-13', now), 'Today')
})

test('a date in the past needs no widening', () => {
  assert.equal(Model.horizonForDue('2026-08-01', new Date(2026, 7, 13)), 'Today')
})

test('a date beyond every view falls back to the widest', () => {
  assert.equal(Model.horizonForDue('2026-12-25', new Date(2026, 7, 13)), 'Next 7 days')
})

test('horizonForDue survives junk', () => {
  assert.equal(Model.horizonForDue('garbage', new Date(2026, 7, 13)), 'Today')
  assert.equal(Model.horizonForDue('', new Date(2026, 7, 13)), 'Today')
})

test('widerHorizon never narrows the current view', () => {
  assert.equal(Model.widerHorizon('Today', 'Tomorrow'), 'Tomorrow')
  assert.equal(Model.widerHorizon('Next 7 days', 'Today'), 'Next 7 days')
  assert.equal(Model.widerHorizon('Tomorrow', 'Tomorrow'), 'Tomorrow')
})

test('adding for tomorrow from a Today view widens to Tomorrow', () => {
  const now = new Date(2026, 7, 13)
  const parsed = Model.parseQuickAdd('Ship the release tomorrow')
  assert.equal(Model.widerHorizon('Today', Model.horizonForDue(parsed.due, now)), 'Tomorrow')
})

test('yesterday is a date word, and needs no widening', () => {
  const parsed = Model.parseQuickAdd('Buy the TLS cert yesterday')
  assert.equal(parsed.title, 'Buy the TLS cert')
  assert.equal(parsed.due, 'yesterday')
  assert.equal(Model.horizonForDue('yesterday', new Date(2026, 7, 13)), 'Today')
})

// --- sync interval -------------------------------------------------------

test('each interval label maps to its seconds', () => {
  assert.equal(Model.syncIntervalSeconds('2 minutes'), 120)
  assert.equal(Model.syncIntervalSeconds('5 minutes'), 300)
  assert.equal(Model.syncIntervalSeconds('15 minutes'), 900)
  assert.equal(Model.syncIntervalSeconds('1 hour'), 3600)
})

test('"Only when opened" disables the timer with zero', () => {
  assert.equal(Model.syncIntervalSeconds('Only when opened'), 0)
})

test('an unknown or missing label falls back to the default', () => {
  assert.equal(Model.syncIntervalSeconds('every fortnight'), 300)
  assert.equal(Model.syncIntervalSeconds(undefined), 300)
  assert.equal(Model.syncIntervalSeconds(''), 300)
})

test('every offered label resolves, so the picker cannot produce a dud', () => {
  for (const label of Model.syncIntervalLabels()) {
    const seconds = Model.syncIntervalSeconds(label)
    assert.equal(typeof seconds, 'number')
    assert.ok(seconds === 0 || seconds >= 120, `${label} -> ${seconds}`)
  }
})

// --- editing -------------------------------------------------------------

function localAllDay(offsetDays) {
  const d = new Date()
  d.setDate(d.getDate() + offsetDays)
  const p = n => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T00:00:00.000+0000`
}

test('a task renders back into the grammar that would have made it', () => {
  const t = { title: 'Renew the cert', tags: ['work', 'ops'], priority: 5, isAllDay: true, dueDate: localAllDay(1) }
  assert.equal(Model.editLineFor(t), 'Renew the cert #work #ops !1 tomorrow')
})

test('the edit line round-trips through the add parser', () => {
  const t = { title: 'Renew the cert', tags: ['work'], priority: 3, isAllDay: true, dueDate: localAllDay(0) }
  const parsed = Model.parseQuickAdd(Model.editLineFor(t))
  assert.equal(parsed.title, 'Renew the cert')
  assert.deepEqual(parsed.tags, ['work'])
  assert.equal(parsed.priority, 3)
  assert.equal(parsed.due, 'today')
})

test('a task with nothing set renders as a bare title', () => {
  assert.equal(Model.editLineFor({ title: 'Someday thing', tags: [], priority: 0 }), 'Someday thing')
})

test('a far-off date falls back to an ISO date rather than a word', () => {
  const line = Model.editLineFor({ title: 'x', tags: [], priority: 0, isAllDay: true, dueDate: localAllDay(9) })
  assert.match(line, /^x \d{4}-\d{2}-\d{2}$/)
})

test('editLineFor tolerates a missing task', () => {
  assert.equal(Model.editLineFor(null), '')
})

test('editArgs always sends tags and priority, so clearing them works', () => {
  const args = Model.editArgs('id1', 'Just a title')
  assert.deepEqual(args, ['update', 'id1', '--title', 'Just a title', '--priority', '0', '--tags', ''])
})

test('editArgs sends a date only when one was typed', () => {
  assert.ok(!Model.editArgs('id1', 'No date here').includes('--due'))
  assert.ok(Model.editArgs('id1', 'Has one tomorrow').includes('--due'))
})

test('editArgs refuses a line with no title left', () => {
  assert.equal(Model.editArgs('id1', '#work !1'), null)
  assert.equal(Model.editArgs('id1', '   '), null)
})

test('parseQuickAdd reports whether a date was actually given', () => {
  assert.equal(Model.parseQuickAdd('Pay rent').dueGiven, false)
  assert.equal(Model.parseQuickAdd('Pay rent tomorrow').dueGiven, true)
})

// --- trailing times ------------------------------------------------------

test('a trailing time range sets a duration on the default day', () => {
  const parsed = Model.parseQuickAdd('Meeting 21:00-22:30')
  assert.equal(parsed.title, 'Meeting')
  assert.equal(parsed.due, 'today')
  assert.equal(parsed.time, '21:00-22:30')
  assert.equal(parsed.dueGiven, true)
})

test('a lone trailing clock is a due hour, and meridiem is normalized', () => {
  assert.equal(Model.parseQuickAdd('Call mum 9pm').time, '21:00')
  assert.equal(Model.parseQuickAdd('Standup 9:30am').time, '09:30')
  assert.equal(Model.parseQuickAdd('Midday thing 12pm').time, '12:00')
  assert.equal(Model.parseQuickAdd('Night 12am').time, '00:00')
})

test('a date and a time combine', () => {
  const parsed = Model.parseQuickAdd('Ship cert 2026-08-31 08:30')
  assert.equal(parsed.title, 'Ship cert')
  assert.equal(parsed.due, '2026-08-31')
  assert.equal(parsed.time, '08:30')
})

test('a bare number or a broken clock stays in the title', () => {
  const finish = Model.parseQuickAdd('Finish 3')
  assert.equal(finish.title, 'Finish 3')
  assert.equal(finish.time, null)
  assert.equal(finish.dueGiven, false)

  const overnight = Model.parseQuickAdd('Ship cert 2026-08-31 25:00')
  assert.equal(overnight.title, 'Ship cert 2026-08-31 25:00')
  assert.equal(overnight.dueGiven, false)
  assert.equal(overnight.time, null)
})

test('the space in "9 pm" is the typist\'s, not the grammar\'s', () => {
  const parsed = Model.parseQuickAdd('test notification on 1:33 am')
  assert.equal(parsed.title, 'test notification')
  assert.equal(parsed.time, '01:33')
  assert.equal(Model.parseQuickAdd('Call mum 9 pm').time, '21:00')
  assert.equal(Model.parseQuickAdd('Meet Pat at 5 PM').time, '17:00')
})

test('"at" and "@" go with the clock instead of being stranded in the title', () => {
  assert.equal(Model.parseQuickAdd('Call mum at 9pm').title, 'Call mum')
  assert.equal(Model.parseQuickAdd('Call mum @ 9pm').title, 'Call mum')
  assert.equal(Model.parseQuickAdd('Call mum @9pm').title, 'Call mum')
  assert.equal(Model.parseQuickAdd('Call mum at 9pm').time, '21:00')
})

test('filler sits between the day and the clock as well as before them', () => {
  const parsed = Model.parseQuickAdd('Standup tomorrow at 9:15 am')
  assert.equal(parsed.title, 'Standup')
  assert.equal(parsed.due, 'tomorrow')
  assert.equal(parsed.time, '09:15')
  assert.equal(Model.parseQuickAdd('Dentist due 2026-09-12 at 14:00').due, '2026-09-12')
})

test('a spaced range is still one duration', () => {
  const parsed = Model.parseQuickAdd('Meeting today 8:30 am - 9:30 am')
  assert.equal(parsed.title, 'Meeting')
  assert.equal(parsed.time, '08:30-09:30')
})

test('a word that merely begins with a meridiem is not a clock', () => {
  assert.equal(Model.parseQuickAdd('Buy 2 amps').title, 'Buy 2 amps')
  assert.equal(Model.parseQuickAdd('Buy 2 amps').dueGiven, false)
  assert.equal(Model.parseQuickAdd('Read 5 pages').dueGiven, false)
  // The "at" inside "cat" is not filler: the clock is taken, the cat stays.
  assert.equal(Model.parseQuickAdd('Feed the cat 9pm').title, 'Feed the cat')
})

// A duration has to survive an edit, which it does by the field pre-filling
// with the range and the CLI reading it back — so both directions must
// round-trip, including one whose end spills past midnight.
function localSpan(startClock, endClock, offsetDays) {
  const base = new Date()
  base.setDate(base.getDate() + (offsetDays || 0))
  const parts = c => c.split(':').map(Number)
  const [sh, sm] = parts(startClock)
  const [eh, em] = parts(endClock)
  const start = new Date(base.getFullYear(), base.getMonth(), base.getDate(), sh, sm)
  const end = new Date(base.getFullYear(), base.getMonth(), base.getDate(), eh, em)
  // Overnight spans are held on the server with the end on the next day,
  // which is exactly what the CLI's overnight rule produces.
  if (end <= start) end.setDate(end.getDate() + 1)
  const z = d => d.toISOString().replace('Z', '+0000')
  return { title: 'Late block', isAllDay: false, startDate: z(start), dueDate: z(end) }
}

test('editLineFor renders a duration back as a range, and it round-trips', () => {
  const line = Model.editLineFor(localSpan('21:00', '22:30'))
  assert.equal(line, 'Late block today 21:00-22:30')
  assert.equal(Model.parseQuickAdd(line).time, '21:00-22:30')
})

test('an overnight duration round-trips with the day pinned to its start', () => {
  const line = Model.editLineFor(localSpan('23:30', '00:30'))
  assert.equal(line, 'Late block today 23:30-00:30')
  assert.equal(Model.parseQuickAdd(line).time, '23:30-00:30')
})

test('editLineFor renders a plain timed task back with its due hour', () => {
  const at = new Date()
  at.setHours(9, 30, 0, 0)
  const line = Model.editLineFor({
    title: 'Thing', tags: [], priority: 0, isAllDay: false,
    startDate: at.toISOString().replace('Z', '+0000'),
    dueDate: at.toISOString().replace('Z', '+0000')
  })
  assert.equal(line, 'Thing today 09:30')
})

test('editArgs and quickAddArgs carry --time', () => {
  const edited = Model.editArgs('id1', 'Fable today 21:00-22:30')
  const at = edited.indexOf('--time')
  assert.ok(at >= 0)
  assert.deepEqual(edited.slice(at, at + 2), ['--time', '21:00-22:30'])

  const added = Model.quickAddArgs('Meeting 9pm')
  const addedAt = added.indexOf('--time')
  assert.deepEqual(added.slice(addedAt, addedAt + 2), ['--time', '21:00'])
})

test('editArgs without a time sends none, so deleting the clock clears it', () => {
  assert.ok(!Model.editArgs('id1', 'Just a title').includes('--time'))
})

// --- the held-action stack -----------------------------------------------

const NOW_MS = 1_000_000

function held(key, offset) {
  return { key, kind: 'complete', title: key, args: ['complete', key], deadline: NOW_MS + offset }
}

test('expirePending splits by deadline and keeps order', () => {
  const list = [held('a', -1), held('b', 2000), held('c', 5000)]
  const { due, remaining } = Model.expirePending(list, NOW_MS)
  assert.deepEqual(due.map(e => e.key), ['a'])
  assert.deepEqual(remaining.map(e => e.key), ['b', 'c'])
})

test('several actions expiring at once come back oldest first', () => {
  const list = [held('a', -3000), held('b', -1000), held('c', 5000)]
  const { due } = Model.expirePending(list, NOW_MS)
  assert.deepEqual(due.map(e => e.key), ['a', 'b'])
})

test('nothing is due before its deadline', () => {
  assert.deepEqual(Model.expirePending([held('a', 1)], NOW_MS).due, [])
})

test('expirePending tolerates an empty or missing list', () => {
  assert.deepEqual(Model.expirePending([], NOW_MS), { due: [], remaining: [] })
  assert.deepEqual(Model.expirePending(null, NOW_MS), { due: [], remaining: [] })
})

test('undo targets the most recent action, not the oldest', () => {
  const list = [held('a', 1000), held('b', 2000), held('c', 3000)]
  assert.equal(Model.topPending(list).key, 'c')
  assert.deepEqual(Model.dropTopPending(list).map(e => e.key), ['a', 'b'])
})

test('undoing repeatedly walks back through the stack', () => {
  let list = [held('a', 1000), held('b', 2000), held('c', 3000)]
  list = Model.dropTopPending(list)
  list = Model.dropTopPending(list)
  assert.deepEqual(list.map(e => e.key), ['a'])
  assert.equal(Model.topPending(list).key, 'a')
})

test('an empty stack has nothing to undo', () => {
  assert.equal(Model.topPending([]), null)
  assert.equal(Model.topPending(null), null)
  assert.deepEqual(Model.dropTopPending([]), [])
})

test('the label says how much is queued behind the offered undo', () => {
  assert.equal(Model.heldSuffix(1), '')
  assert.equal(Model.heldSuffix(2), '  +1 more')
  assert.equal(Model.heldSuffix(4), '  +3 more')
})

// --- bar label switching -------------------------------------------------

test('the bar label cycles through its three modes and wraps', () => {
  assert.equal(Model.cycleBarLabel('Count'), 'Next')
  assert.equal(Model.cycleBarLabel('Next'), 'Icon')
  assert.equal(Model.cycleBarLabel('Icon'), 'Count')
})

test('an unknown mode recovers rather than sticking', () => {
  assert.equal(Model.cycleBarLabel('nonsense'), 'Next')
  assert.equal(Model.cycleBarLabel(undefined), 'Next')
})

test('each mode has a short description for the tooltip', () => {
  assert.equal(Model.barLabelDescription('Count'), 'counts')
  assert.equal(Model.barLabelDescription('Next'), 'next task')
  assert.equal(Model.barLabelDescription('Icon'), 'icon only')
})

// --- due notifications ---------------------------------------------------

// A timed task at a given offset from NOW, in minutes. Built from a local
// Date like every other fixture here, so the tests hold in any timezone.
function at(minutesFromNow, over) {
  const when = new Date(NOW.getTime() + minutesFromNow * 60000)
  return task(Object.assign({ isAllDay: false, dueDate: iso(when) }, over))
}

test('a task announces itself once its moment has arrived, and never twice', () => {
  const list = [at(-1, { id: 'a', title: 'Standup' })]
  const first = Model.dueNotifications(list, NOW, {}, {})
  assert.deepEqual(first.due.map(t => t.id), ['a'])

  // Feeding the map back is what the service does; the second pass is silent.
  const second = Model.dueNotifications(list, NOW, first.notified, {})
  assert.deepEqual(second.due, [])
})

test('a task still in the future is not announced', () => {
  const result = Model.dueNotifications([at(30, { id: 'a' })], NOW, {}, {})
  assert.deepEqual(result.due, [])
  assert.deepEqual(result.notified, {})
})

test('lead minutes announce a task before its time, not after', () => {
  const list = [at(10, { id: 'a' })]
  assert.deepEqual(Model.dueNotifications(list, NOW, {}, { leadMinutes: 5 }).due, [])
  assert.deepEqual(
    Model.dueNotifications(list, NOW, {}, { leadMinutes: 15 }).due.map(t => t.id),
    ['a']
  )
})

test('a moment older than the catch-up window is dropped, not announced late', () => {
  const result = Model.dueNotifications([at(-90, { id: 'a' })], NOW, {}, {})
  assert.deepEqual(result.due, [])
  // And not recorded either: the clock only moves forward, so it can never
  // come back around and claim a slot in the map.
  assert.deepEqual(result.notified, {})
})

test('a moment from the gap since the last check still arrives once', () => {
  // The shell was restarted, or the laptop was asleep, at 13:30.
  const result = Model.dueNotifications([at(-30, { id: 'a' })], NOW, {}, {})
  assert.deepEqual(result.due.map(t => t.id), ['a'])
})

test('an all-day task is never announced — its due time is midnight', () => {
  const list = [task({ id: 'a', isAllDay: true, dueDate: '2026-08-12T00:00:00.000+0000' })]
  assert.deepEqual(Model.dueNotifications(list, NOW, {}, {}).due, [])
})

test('completed, abandoned and undated tasks are never announced', () => {
  const list = [
    at(-1, { id: 'done', status: 2 }),
    at(-1, { id: 'wont', status: -1 }),
    at(-1, { id: 'gone', deleted: 1 }),
    task({ id: 'undated', isAllDay: false })
  ]
  assert.deepEqual(Model.dueNotifications(list, NOW, {}, {}).due, [])
})

test('a duration is announced when it starts, not when it ends', () => {
  // 13:55-15:00: the block is under way, so it is news now, not at 15:00.
  const meeting = span(
    new Date(NOW.getTime() - 5 * 60000),
    new Date(NOW.getTime() + 60 * 60000),
    { id: 'm', title: 'Review' }
  )
  const result = Model.dueNotifications([meeting], NOW, {}, {})
  assert.deepEqual(result.due.map(t => t.id), ['m'])
  // The key is the start instant, which is what was announced.
  assert.equal(
    Object.keys(result.notified)[0],
    'm@' + Model.taskStartDate(meeting).getTime()
  )
})

test('a recurring task announces itself again once its due date rolls forward', () => {
  const today = [at(-1, { id: 'daily', title: 'Vitamins' })]
  const first = Model.dueNotifications(today, NOW, {}, {})
  assert.deepEqual(first.due.map(t => t.id), ['daily'])

  // Same id, tomorrow's instant — the shape TickTick returns after the
  // completion rolls the task forward.
  const tomorrow = new Date(NOW.getTime() + 24 * 60 * 60000)
  const rolled = [task({ id: 'daily', isAllDay: false, dueDate: iso(tomorrow) })]
  const later = Model.dueNotifications(rolled, tomorrow, first.notified, {})
  assert.deepEqual(later.due.map(t => t.id), ['daily'])
})

test('a completion held in the undo window is not announced', () => {
  const list = [at(-1, { id: 'a' })]
  const result = Model.dueNotifications(list, NOW, {}, { skipIds: { a: true } })
  assert.deepEqual(result.due, [])
  // Nor recorded, so a completion that fails still gets its reminder.
  assert.deepEqual(result.notified, {})
})

test('the map keeps only what can still suppress something', () => {
  const seen = {
    'stale@1': true,
    'gone@2': true
  }
  const list = [at(-1, { id: 'a' })]
  const result = Model.dueNotifications(list, NOW, seen, {})
  // Keys for tasks no longer in the cache, and for moments past the window,
  // are rebuilt away rather than accumulating over weeks of uptime.
  assert.deepEqual(Object.keys(result.notified), ['a@' + Model.taskDueDate(list[0]).getTime()])
})

test('everything that crosses at once is announced in start order', () => {
  const list = [at(-1, { id: 'late', title: 'B' }), at(-20, { id: 'earlier', title: 'A' })]
  const result = Model.dueNotifications(list, NOW, {}, {})
  assert.deepEqual(result.due.map(t => t.id), ['earlier', 'late'])
})

// --- notification wording ------------------------------------------------

test('one task is its own notification: title as the summary, due time under it', () => {
  const args = Model.notifyArgs([at(0, { id: 'a', title: 'Standup' })], NOW)
  assert.deepEqual(args.slice(0, 5), ['-a', 'TickTick', '-u', 'normal', '--'])
  assert.equal(args[5], 'Standup')
  assert.equal(args[6], 'Due 14:00')
})

test('several tasks become one notification, not one popup each', () => {
  const args = Model.notifyArgs([
    at(0, { id: 'a', title: 'Standup' }),
    at(0, { id: 'b', title: 'Ship it' })
  ], NOW)
  assert.equal(args[5], '2 tasks due')
  assert.deepEqual(args[6].split('\n'), ['14:00  Standup', '14:00  Ship it'])
})

test('a long batch lists the first few and counts the rest', () => {
  const many = []
  for (let i = 0; i < 8; i++) many.push(at(0, { id: 'n' + i, title: 'Task ' + i }))
  const args = Model.notifyArgs(many, NOW)
  const lines = args[6].split('\n')
  assert.equal(lines.length, 6)
  assert.equal(lines[5], '+3 more')
})

test('a title is defanged and elided before the daemon sees it', () => {
  const args = Model.notifyArgs([at(0, { id: 'a', title: '<b>bold</b> ' + 'x'.repeat(80) })], NOW)
  assert.ok(args[5].indexOf('<') === -1)
  assert.equal(args[5].length, 60)
  assert.ok(args[5].endsWith('…'))
})

test('nothing due is no notification at all', () => {
  assert.equal(Model.notifyArgs([], NOW), null)
  assert.equal(Model.notifyArgs(null, NOW), null)
})

// --- announced-keys file -------------------------------------------------

test('the announced-keys file survives an empty, truncated, or wrong-shaped file', () => {
  assert.deepEqual(Model.parseNotified(''), {})
  assert.deepEqual(Model.parseNotified('{"a@1":tru'), {})
  assert.deepEqual(Model.parseNotified('[1,2]'), {})
  assert.deepEqual(Model.parseNotified('null'), {})
  assert.deepEqual(Model.parseNotified('{"a@1":true,"b@2":false}'), { 'a@1': true })
})

test('a saved map round-trips through the file the service writes', () => {
  const result = Model.dueNotifications([at(-1, { id: 'a' })], NOW, {}, {})
  assert.deepEqual(Model.parseNotified(JSON.stringify(result.notified)), result.notified)
})

// --- quick-add preview ---------------------------------------------------

test('the preview says which day and hour the line would land on', () => {
  const p = t => Model.quickAddPreview(Model.parseQuickAdd(t), false)
  assert.equal(p('Call mum at 9pm'), 'Today · 21:00')
  assert.equal(p('Pay rent tomorrow'), 'Tomorrow')
  assert.equal(p('Dentist on 2026-09-12 14:00'), '2026-09-12 · 14:00')
})

test('a duration is previewed as the range, with the panel\'s own dash', () => {
  assert.equal(
    Model.quickAddPreview(Model.parseQuickAdd('Meeting today 8:30-9:30'), false),
    'Today · 08:30–09:30')
})

test('an undated line previews the day it will actually land on', () => {
  // Adding always sends a due date, so "no date" is not "no due date".
  assert.equal(Model.quickAddPreview(Model.parseQuickAdd('Buy milk'), false), 'Today')
})

test('an undated edit says the task keeps its own date, because it does', () => {
  assert.equal(Model.quickAddPreview(Model.parseQuickAdd('Buy milk'), true), 'Date unchanged')
  assert.equal(Model.quickAddPreview(Model.parseQuickAdd('Buy milk tomorrow'), true), 'Tomorrow')
})

test('a line that would create nothing previews nothing', () => {
  assert.equal(Model.quickAddPreview(Model.parseQuickAdd(''), false), '')
  assert.equal(Model.quickAddPreview(Model.parseQuickAdd('   #tag  '), false), '')
  assert.equal(Model.quickAddPreview(null, false), '')
})

test('the line an edit pre-fills previews as the task it came from', () => {
  const line = Model.editLineFor(localSpan('21:00', '22:30'))
  assert.equal(Model.quickAddPreview(Model.parseQuickAdd(line), true), 'Today · 21:00–22:30')
})

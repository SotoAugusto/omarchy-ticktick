const test = require('node:test')
const assert = require('node:assert')
const Model = require('../Model.js')

const NOW = new Date(2026, 7, 12, 14, 0, 0) // 2026-08-12 14:00 local

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
  const morning = task({ isAllDay: false, dueDate: '2026-08-12T09:00:00.000-0500' })
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
  assert.equal(
    Model.undoLabel({ kind: 'complete', title: 'Pay rent' }, 5),
    'Completed Pay rent · undo 5s')
  assert.equal(
    Model.undoLabel({ kind: 'checkin', title: 'Read' }, 3),
    'Checked in Read · undo 3s')
  assert.ok(Model.undoLabel({ kind: 'complete', title: 'x'.repeat(80) }, 2).length < 50)
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

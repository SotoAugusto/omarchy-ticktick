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
    Model.dueTier(task({ isAllDay: false, dueDate: '2026-08-12T09:00:00.000-0500' }), NOW),
    'overdue')
})

test('parseCache defaults tags to an empty list', () => {
  assert.deepEqual(Model.parseCache('').tags, [])
})

// --- quick-add syntax ----------------------------------------------------

test('a bare title is due today with no tags or priority', () => {
  assert.deepEqual(Model.parseQuickAdd('Pay rent'),
    { title: 'Pay rent', tags: [], priority: 0, due: 'today', dueGiven: false })
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
    { title: 'Ship it', tags: [], priority: 0, due: 'tomorrow', dueGiven: true })
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

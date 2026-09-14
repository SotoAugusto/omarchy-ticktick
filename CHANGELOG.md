# Changelog

## Unreleased

### Fixed

- The keyboard help's key chips no longer lose a sliver of their left edge.
  Their rail was a fixed width that `tomorrow` and `!1 !2 !3` overran by 2px;
  it is now as wide as the widest key in the font the panel actually uses, so
  a theme with a larger caption size cannot clip them either.
- The README now says that shift+enter also offers the likelier reading of a
  full range the grammar reads implausibly (`call 1:30-2pm`, read as 01:30 to
  14:00, is offered 13:30–14:00), which 0.5.1 already did.

## 0.5.1 — 2026-09-13

### Added

- Shift+enter takes the range a half-typed line means. `gym 6 - 7am`,
  `gym 6-7am` and `call 10 to 11am` end in a bare hour, so the grammar cannot
  read them as a range — and `Level 3 - 9pm` has the same shape and means what
  it reads, so it does not guess. A second line under the field offers the
  range (`⇧ enter → 06:00–07:00`), naming the day when one is written in front
  of it, and shift+enter rewrites the line to `gym 6am-7am` before adding it —
  tags and priority after the range come along, and a block may run past
  midnight. The first line still says exactly what plain enter will do; plain
  enter is unchanged, and shift+enter with nothing on offer is plain enter.
  The unspaced `gym 6-7am`, which plain enter still adds all-day, gets the
  offer too.

## 0.5.0 — 2026-09-13

### Added

- Due notifications, off by default. Turn `notifyOnDue` on and the desktop
  says so the moment a task's time arrives — the bar count is something you
  have to look at, and this is the half that comes to you.
  `notifyLeadMinutes` moves it earlier. A task with a duration is announced
  when it **starts**, not as it ends; a task with a date but no time is never
  announced, because its due time is midnight. Several tasks crossing at once
  become one notification listing them rather than one popup each.

  Nothing new polls: the check rides the clock the bar already runs once a
  minute, and the only process it starts is `notify-send`. What has been
  announced is keyed on the moment rather than the task, so a recurring task
  that rolls forward — or one you reschedule — earns a fresh reminder, and
  that record is kept in `~/.local/state/omarchy/ticktick/notified.json` so a
  shell restart at 14:31 does not announce the 14:30 meeting again. A moment
  is only announced within an hour of passing, so a laptop that slept all
  morning reports the last hour and not the whole of it. Switching it on does
  not replay what is already past, though a reminder still ahead of its moment
  goes out; a task completed in the undo window stays quiet; and a reminder
  `notify-send` could not deliver is tried again rather than counted as sent.

- The quick-add field shows what it understood, under the line you are
  typing: `Today · 21:00`, or plain `Today` when you typed no time. The
  grammar is narrow and a clock it does not take is not an error — the words
  stay in the title and the task lands all-day, which is also a task that
  never notifies — so the hint says `time not recognised` when that happens,
  names the task (`called “gym 6 -”`) when the text before a clock looks like
  the start of a range, and leads with `Renaming to “…”` when an edit would
  change a task's name. All of it is in front of you before enter rather than
  after.

### Fixed

- Quick add takes the times people actually type. A space before the
  meridiem works (`1:33 am`, not only `1:33am`), `at` and `@` join `for`,
  `on`, `due` and `by` as filler in front of a clock, and the filler is
  allowed between the day and the clock as well as before them — so
  `Standup tomorrow at 9:15 am` is a task called *Standup*, due tomorrow
  morning, where it used to be a task called *Standup tomorrow at 9:15 am*
  due today with no time at all. `at` was the one preposition missing from
  that list, and the one most likely to be typed. In front of a day word it
  is left alone (`Look at today` is a task called *Look at*), and `@` counts
  there only attached, as in `standup @tomorrow`. A range spelled with a bare
  hour in the new spaced form — `gym 6 - 7 am`, `10 to 11 am` — is left in
  the title rather than read as its end; the glued `gym 6 - 7am` reads as it
  always did.
- Editing a task whose title ends in `for`, `on`, `by` or `due` no longer
  drops that word. The edit line is read like quick add, where those words in
  front of a day are filler, but a line that still begins with the task's own
  title has not renamed it — so `e` then enter leaves *Notes for* as it was,
  and so does changing its day.
- The panel's own shortcut list no longer advertises `"fri 9:30-11"`, which
  never parsed: weekday names are not date words here, and a clock needs a
  colon or a meridiem.

## 0.4.0 — 2026-08-30

### Added

- Task details. A chevron on the row (or `o`) expands a task's full
  description and its subtasks. Subtasks are rows of their own: click
  anywhere on one, or walk into them with the arrows and flip with enter —
  `o` folds the task and steps back out. A flip goes straight out, no undo
  window; offline it queues and replays like every other write.
- `c` copies the selected task as a markdown note: `# Title`, one metadata
  line (list · tags · priority · due), the description verbatim, and the
  subtasks as a GitHub-style checklist. Goes through `wl-copy`, which must
  be on your `PATH`.
- The keyboard shortcut list is grouped — tasks & habits, quick add field,
  focus timer, panel — with each key in a chip, so sixteen shortcuts scan
  by section instead of reading as one wall.

### Changed

- Tasks with a duration rank ahead of plain dated tasks once the late
  backlog is accounted for. An appointment is pinned to a moment, while an
  all-day task keys at midnight — by time alone it used to bury an evening
  block under every floating task dated today.

### Fixed

- Editing a task no longer destroys its duration. The edit field now
  pre-fills with the task's times (`Fable #boletokk today 21:00-22:30`), a
  trailing clock in quick-add and edit sets when — a range becomes a
  duration, a lone time a due hour — and the CLI gained `--time` to match.
  An end that is not after the start spills into the next day, so
  `23:30-00:30` means overnight. Delete the clock from the line and the
  duration goes with it: the line is the whole truth.
- Tasks with a duration (say, a meeting 8:30–9:30) now show their whole
  block in the panel row (`08:30–09:30`) instead of just the end time, and
  the day marker follows the start. They are also ordered by when they
  start, so a meeting beginning 15:30 ranks ahead of a 16:00 due time, and
  one starting late tonight is no longer pushed out of the Today view by
  its after-midnight end.

## 0.3.1 — 2026-08-22

### Fixed

- API responses are now read with an 8 MB cap (64 KB for error bodies)
  instead of buffered without limit, so a misbehaving endpoint cannot
  exhaust memory.
- Every `Text` item showing server-provided strings (task titles, tag and
  habit names, error messages) pins `textFormat: Text.PlainText`; strings
  handed to the shell's own components (the bar label and tooltips) have
  angle brackets swapped for lookalikes. HTML-shaped content in a task
  title now renders as literal text everywhere.
- The two timed-overdue tests no longer hardcode a `-0500` offset and pass
  in every timezone, not just west of UTC-4.

## 0.3.0 — 2026-08-22

### Added

- `Open in TickTick ›` and the `Open TickTick` button launch the TickTick
  desktop app when it is on your `PATH`, and fall back to the web app when it
  is not.

### Fixed

- The panel no longer sits on "not connected" after a successful login on a
  fresh install. `Service.qml` now reloads the cache when the CLI exits
  instead of trusting the file watcher, which never attaches when the state
  directory does not exist yet — and so never fires for later writes either.

## 0.2.0 — 2026-08-14

### Added

- Edit a task with `e`. The field fills with the line that would have created
  it (`Renew the cert #work !1 tomorrow`); change it and press enter.
- Quick-add syntax: `#tag`, `!1`/`!2`/`!3`, and a trailing date word.
- Focus timer using your TickTick durations. Finished blocks upload to your
  focus statistics; a block stopped early is discarded, not logged.
- Offline outbox. Writes made without a connection are queued and applied
  locally, then replayed against current server state.
- Undo window on completions and check-ins, held as a stack so clearing
  several rows in a row stays reversible.
- Keyboard navigation, with the shortcut list on `?` and a button beside it.
- Range switch — today, tomorrow, or the next seven days.
- Tag colours from TickTick; due state painted from your Omarchy theme.
- Long titles scroll when you point at them.
- `update`, `delete`, and `pomo` commands in the CLI.

### Changed

- **`refreshIntervalSec` is now `syncInterval`**, a choice rather than a
  number of seconds. If you set the old key by hand, set it again.
- Shared state moved into a service plugin, so a multi-monitor desktop runs
  one sync timer, one focus clock, and one cache instead of one per screen.
- A write refreshes only what it could have changed — about 0.6s instead of
  2.0s.
- Connecting happens in the panel: paste the browser's `t` cookie into the
  setup card.

### Removed

- `--save-password` and its keyring storage. TickTick refuses scripted
  password logins, so the session could never renew itself with it.

## 0.1.0

First release. Tasks due today and habit check-ins in the bar, with one-click
complete and check-in.

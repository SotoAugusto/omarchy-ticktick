# Changelog

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

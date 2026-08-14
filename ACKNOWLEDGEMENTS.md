# Acknowledgements

No third-party code is vendored into this plugin. What follows is what it was
built on, learned from, or runs inside — including cases where the debt is
knowledge rather than code, since those are the ones that are easy to leave
unsaid.

## Runs inside

**[Omarchy](https://github.com/basecamp/omarchy)** — MIT. The desktop and the
shell that hosts this. The plugin contract (`manifest.json`, `kinds`,
`entryPoints`), the `qs.Ui` component kit (`BarWidget`, `Panel`,
`KeyboardPanel`, `PanelActionButton`, `TextField`, `PanelToolTip`, and others),
and the `qs.Commons` `Style` / `Color` tokens are all Omarchy's.

Three of its solutions were adopted after trying to invent worse ones:

- The **service + view split** is modeled on `plugins/services/media`, which
  keeps shared state in a `service`-kind plugin and reaches it through
  `shell.serviceFor(id)`.
- **Focused-monitor panel routing** uses `Bar.findPanelWidget()`, which already
  asks Hyprland which output is focused.
- The **bar widget + popup structure** follows `plugins/panels/weather`.

**[Quickshell](https://github.com/quickshell-mirror/quickshell)** — LGPL-3.0.
The QML shell framework underneath: `Process`, `FileView`, `IpcHandler`,
`SystemClock`, and the layer-shell windows the panel is drawn in.

**[Nerd Fonts](https://github.com/ryanoasis/nerd-fonts)** — the icon glyphs in
the bar and panel (checklist, clock, plug, circles, flame) are Nerd Font
codepoints, rendered from whichever patched font the user's bar is configured
with. The project aggregates several icon sets under their own licenses.

## Layout and conventions

**[tmn73/omarchy-calendar](https://github.com/tmn73/omarchy-calendar)** — MIT.
The first third-party Omarchy plugin I read. Its shape — `manifest.json` plus
`BarWidget.qml`, `Panel.qml`, a node-testable `Model.js`, and `tests/` — is the
layout used here, along with the idea of keeping all fragile logic in plain JS
so it can be tested without a running shell.

## TickTick's private v2 API

The API this speaks is undocumented. These projects worked parts of it out
first, and reading them saved a great deal of guessing. No code was copied.

**[lazeroffmichael/ticktick-py](https://github.com/lazeroffmichael/ticktick-py)**
— MIT. The `x-device` header shape and the `/api/v2` base. Worth noting for
anyone following the same path: its login path `/user/signin` now returns 404,
and the live endpoint is `/user/signon`.

**[OliverStoll/ticktick-api-v2](https://github.com/OliverStoll/ticktick-api-v2)**
— Apache-2.0. The habit endpoints — `GET /habits`,
`POST /habitCheckins/query`, `POST /habitCheckins/batch` — and
`/pomodoros/timeline`. Habits do not exist in TickTick's documented Open API at
all, so this is the reason the feature is possible.

**[partymola/ticktick-mcp](https://github.com/partymola/ticktick-mcp)** —
GPL-3.0. Documented that the sign-on endpoint is rate limited, which is why
this plugin caches its session token rather than authenticating per call.

**TickTick's own web client** — the exact sign-on payload and query string were
read from the public JavaScript bundle served by `ticktick.com`, after the
published wrappers disagreed with each other. Observation of a public
interface; nothing was copied.

## Publishing

**[HANCORE-linux/omarchy-plugin-marketplace](https://github.com/HANCORE-linux/omarchy-plugin-marketplace)**
— MIT. Community marketplace whose `SUBMISSION.md` set the requirements this
repository follows: a root `manifest.json`, a README with installation *and*
removal instructions, a license file, documented dependencies, a namespaced
plugin id, and a single root `preview.png`.

## Not affiliated

This is an unofficial, community-built plugin. It is not affiliated with,
endorsed by, or supported by **TickTick** (Appest Inc.), and it speaks an API
they do not document or guarantee. TickTick is their trademark. Breakage is
this plugin's problem, not theirs — please do not report it to them.

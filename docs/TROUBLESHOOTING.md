# Troubleshooting

[← back to the README](../README.md)

## Look here first

```powershell
# GlazeWM's own complaints. A config that fails to parse is NOT applied,
# so one typo silently reverts every change in the file.
Get-Content ~\.glzr\glazewm\errors.log -Tail 20

# What the daemon has been doing.
Get-Content ~\.glzr\glazewm\autotiling.log -Tail 30

# Is the daemon alive, and where? /ping answers only if it is really ours.
Invoke-RestMethod http://127.0.0.1:6124/ping
```

If that times out, the bridge may have moved: something else holding 6124 makes
the daemon step to the next port. Where it landed:

```powershell
Get-Content ~\.glzr\glazewm\bridge-port
6124, 6125, 6126, 6127 | ForEach-Object {
    try { Invoke-RestMethod "http://127.0.0.1:$_/ping" -TimeoutSec 1 } catch {}
}
```

## Nothing tiles the way it should

Check the daemon is running. The bridge call above is the quickest test; if it
times out, nothing is listening on 6124.

Start it by hand:

```powershell
node ~\.glzr\glazewm\autotiling.mjs
```

(MSI installs don't have `autotiling.mjs` or Node.js — run the standalone
exe directly instead: `~\.glzr\glazewm\autotiling.exe`.)

Run in the foreground it prints the same lines it writes to the log, and any
startup error goes to the console instead of vanishing.

If it says `another instance is already running, exiting`, one really is up —
the daemon verifies that by asking the port who it is, so the message is not a
guess. To find and stop it:

```powershell
netstat -ano | Select-String '127.0.0.1:612'   # the last column is the PID
Stop-Process -Id <pid>
```

A different message, `port 6124 is taken by something that is not us`, means an
unrelated program holds it and the daemon moved on. That is not a failure, but
if all four candidates are taken it gives up with
`no free port in 6124, 6125, 6126, 6127`.

## The mouse gestures do nothing

1. Is AutoHotkey running? There should be exactly one `AutoHotkey64` process.
2. Is it **v2**? The script will not load under v1.
3. Turn on `DEBUG_ENABLED := true` at the top of `glaze-mouse.ahk`, reload it,
   try a gesture, and read `glaze-mouse.log`. An empty bridge response means the
   daemon is down.

If the script fails to load at all, suspect an identifier collision: AutoHotkey
v2 is **case-insensitive**, so a variable named `DEBUG` clashes with a function
named `Debug()` and the whole file refuses to load — no hotkeys, no log. See
[Mouse](MOUSE.md#tuning).

## Focus does not follow the mouse

Hover focus is `glaze-mouse.ahk`'s job, not GlazeWM's — the shipped config has
`focus_follows_cursor: false` for that reason. So the checks are the ones for
[the mouse gestures](#the-mouse-gestures-do-nothing) first: AutoHotkey running,
v2, and a daemon that answers.

If gestures work and hover does not, check your GlazeWM version first:
`focus --container-id`, which this needs, arrived in **3.9.0**, and
[the requirements](INSTALL.md#requirements) ask for 3.10 in any case.

```powershell
glazewm query app-metadata     # or look at the daemon log
```

The daemon says so in the log when the command is missing:

```
this GlazeWM will not focus a window by id (needs 3.9.0 or newer): ...
focusing a window by id failed 5 times in a row: ...
```

`Invoke-RestMethod http://127.0.0.1:6124/ping` reports the same thing as
`focusById`. `null` there means the question has not been answered yet, not that
anything is wrong — the probe needs a focused window, so it waits for one.

When that happens the script falls back to activating windows natively, so hover
focus still works; what it cannot do that way is move focus to an empty monitor.
Upgrading GlazeWM is the real fix. Failing that, go back to the built-in
version: set
`focus_follows_cursor: true` in `config.yaml` and `FOCUS_FOLLOWS_MOUSE := false`
at the top of `glaze-mouse.ahk`. Details in
[Mouse](MOUSE.md#if-hover-focus-does-nothing).

Focus arriving somewhere you were only passing through means the opposite
problem: raise `FOCUS_DWELL_MS`.

## A window floats that should be tiled

The daemon floats windows it recognises as popups. Its reason is in the log:

```powershell
Get-Content ~\.glzr\glazewm\autotiling.log -Tail 20 | Select-String popup
```

```
popup: floated "Preferences" (someapp) — cannot be resized
```

`cannot be resized` is the rule that occasionally catches a small main window.
Either turn it off for everything, in the `POPUPS` block at the top of
`autotiling.mjs`:

```js
floatNonResizable: false,
```

or, better, name the one application:

```js
neverFloat: ['someapp'],
```

Restart the daemon afterwards. The reverse case — something that should float
and does not — takes `alwaysFloat` in the same block. What the decision was made
from:

```powershell
~\.glzr\glazewm\wm-helpers.exe inspect <hwnd>
```

Full explanation in [Popups](POPUPS.md#policy-lives-in-the-daemon).

## A placed window lands in the wrong region

Check the log: `/place` records what it asked for and what it got.

```
place: handle 123 asked 759x1068 @1155,6, got 1400x1068 @1155,6 — moved to 514,6
```

That line means the application refused to be made that narrow — it has a
minimum size — and the window was slid back to where it still fits rather than
being left hanging over its neighbour. The answer carries `"honored": false` for
the same reason. There is no fix for a minimum size other than giving the window
a bigger share.

It used to be able to mean something else, and if you are on an older copy of
this repository it still can: placement went through `set-floating`, whose
geometry GlazeWM ignores once a window has been moved by anything at all, so the
*second* placement of a window silently kept the first one's size and this line
blamed the application for it. Placement is `size` and `position` now, which
carry no such condition.

If instead the window went to another monitor, check the `ws` you passed: it is
optional now, and leaving it out places the window on the workspace it is
already on. Passing one *moves* the window there first.

## A keybinding does nothing

Almost always a config that did not parse. Check `errors.log`; GlazeWM keeps
running with the previous configuration, so the symptom is "my new binding does
nothing" rather than anything more obvious.

If the config is fine, check whether Windows is eating the combination —
[the list of ones to avoid](KEYBINDINGS.md#windows-shortcuts-worth-leaving-alone).

## A letter key stops typing

Look at your bindings for that letter with `Win`. `Win+S` is the famous one: bind
it and the plain `s` key stops producing anything, while `Shift+S` still works.
The tell is that it depends on Shift being **physically held**, not on the
letter's case — with Caps Lock on it still fails.

## An application fights the tiling

Some windows do not survive being resized. Add an ignore rule in `config.yaml`:

```yaml
window_rules:
  - commands: ['ignore']
    match:
      - window_process: { equals: 'TheApp' }
```

To find the process or class name:

```powershell
~\.glzr\glazewm\wm-helpers.exe classify <hwnd> normal
```

## The taskbar shows over a fullscreen game

Its own page: [Fullscreen games](FULLSCREEN-GAMES.md#verifying-it).

## GlazeWM will not take commands from a script

GlazeWM runs elevated, so launching `glazewm.exe` from a normal shell fails with
*"the requested operation requires elevation"*. The IPC socket does **not** need
elevation, so go through it instead:

```powershell
Invoke-RestMethod "http://127.0.0.1:6124/cmd?c=$([uri]::EscapeDataString('wm-reload-config'))"
```

## Reinstalling wiped my bindings

It should not: `install.ps1` carries the `PERSONAL` regions across. If your
bindings were outside those regions, they were replaced — the previous file is
next to the new one as `config.yaml.bak`. Move them inside the region and it will
not happen again. See [Customizing](CUSTOMIZING.md#where-your-settings-go).

## Starting over

```powershell
Copy-Item ~\.glzr\glazewm\config.yaml.bak ~\.glzr\glazewm\config.yaml
```

then `Alt+Shift+R`. Deleting `config.yaml` entirely also works: GlazeWM writes a
fresh default on the next start.

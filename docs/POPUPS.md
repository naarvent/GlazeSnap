# Popups and placement

[← back to the README](../README.md)

Two problems that turn out to be the same one: a window is a rectangle to a
tiling WM, and some windows are not rectangles you want tiled.

## Why a dialog must not be tiled

GlazeWM tiles what it is given. Open a "Save as" box and the layout is
rearranged around it: every window on the workspace shrinks to make room, the
box gets a slot it never asked for and usually cannot fill, and when you dismiss
it everything moves back. Nothing is broken afterwards, but the work of reading
the screen has to be done again, twice, for a box that was on screen for four
seconds.

The same goes for tool palettes, credential prompts, progress boxes and the
small fixed-size windows applications use for preferences.

## Naming them is not enough

GlazeWM's `window_rules` match on process, class and title. That covers the
cases you can name in advance, and the config does name a few:

```yaml
- commands: ['set-floating --centered=true --shown-on-top=true']
  match:
    - window_class: { equals: '#32770' }
```

`#32770` is the class Windows registers for every dialog box, so that one line
covers a lot of them. But a rule can only match what it was told about, and what
actually makes a window a popup is none of those three things:

| Signal | What it means | Visible to a window rule? |
|---|---|---|
| `GetWindow(GW_OWNER)` | another window owns this one — a dialog, a palette | no |
| owner is disabled | the dialog is **modal** | no |
| `WS_EX_TOOLWINDOW` | "I am a utility window" | no |
| no `WS_THICKFRAME`, no `WS_MAXIMIZEBOX` | it cannot be resized, so it cannot be tiled honestly | no |
| `WS_EX_APPWINDOW` | "I am a main window, put me on the taskbar" | no |

None of that reaches the IPC either. It is Win32 window state, so reading it is
a job for `wm-helpers`.

## What actually happens

```
window opens
   │
   ├─ window_rules match?  ──yes──>  floated by GlazeWM, no flash
   │
   └─ daemon sees a window it has not seen before
          │
          wm-helpers inspect <hwnd>     style bits, owner, class, size
          │
          popupVerdict(facts)           policy, in autotiling.mjs
          │
          ├─ not a popup  ->  left tiled
          └─ a popup      ->  set-floating --centered=true --shown-on-top=true
                              then slid back inside the workspace if needed
```

All of this needs `wm-helpers.exe`, and needs it current — `inspect` is newer
than the taskbar fix, so a helper built before it makes the daemon log the
failure and leave every window tiled. `.\install.ps1` rebuilds it. Without the
helper at all, the window rules above still work and nothing else does; the
startup line in the log says which of the two you have.

The daemon finds new windows by diffing the window list rather than by reading
the event payload: events are coalesced and can be dropped, but a window that
exists now and did not exist a moment ago is a fact that survives both. Windows
already open when the daemon starts are recorded and left alone — restarting it
does not go and float every dialog that has been sitting there since the
morning. Nothing counts as new until that recording has finished, or a window
opening in the same instant would make the whole desktop look new.

The order of the tests is the interesting part. Explicit claims first:
`WS_EX_APPWINDOW` means the application says it is a main window, and that
outranks every guess below it. Then "does it cover the monitor", then ownership,
then the dialog classes, and only then the shape-based heuristics.

The monitor test is there for borderless fullscreen games, which have no resize
border and no maximize box: every shape-based test calls them a popup, and
floating one would centre it and then slide it inside the workspace, a few
pixels off the monitor edge it was covering exactly.

## Policy lives in the daemon

At the top of `autotiling.mjs`:

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | turn the whole thing off |
| `floatOwned` | `true` | float windows another window owns |
| `floatToolWindows` | `true` | float `WS_EX_TOOLWINDOW` |
| `floatNonResizable` | `true` | float what cannot be resized |
| `smallFraction` | `0.6` | a borderless popup counts as one below this share of the work area |
| `neverFloat` | `[]` | process names to leave tiled whatever they look like |
| `alwaysFloat` | `[]` | process names to always float |

`floatNonResizable` is the rule to reach for first if something floats that you
wanted tiled: it is the one that can catch a small main window. `neverFloat` is
the narrower fix — add the process name, restart the daemon, done.

To see what the daemon decided:

```powershell
Get-Content ~\.glzr\glazewm\autotiling.log -Tail 20
```

```
popup: floated "Save As" (explorer) — modal dialog
popup: floated "Find and Replace" (Code) — owned by Code
fit: "Preferences" 3210,-120 -> 1274,6 inside workspace 2
```

To ask about one window yourself:

```powershell
~\.glzr\glazewm\wm-helpers.exe inspect <hwnd>
```

It prints the facts the decision was made from — style bits, owner, class,
rectangle and the work area it sits in.

## Windows that land in the wrong place

The other half. A floating window has to be *somewhere*, and several things put
it somewhere wrong.

**Off the screen entirely.** Applications place their own dialogs, and they get
it wrong often enough: centred on a monitor that has since been unplugged, or on
coordinates remembered from a different resolution. A dialog whose buttons are
past the edge cannot be answered, and it is usually modal. Every popup the
daemon floats is checked against its workspace and slid back inside if it is
hanging off. `Alt+Shift+F` does the same to the focused window by hand.

**On the wrong workspace.** `/place` used to set coordinates without checking
where the window lived. Placing a window into workspace 3 while it sat on
workspace 1 gave it geometry that was right for the other monitor and left it
where it was. It now moves the window first, and `ws` is optional — leave it out
and the window is placed on the workspace it is already on.

**A rectangle the window refuses.** An application with a minimum size larger
than the slot keeps its own size, and what it does with the excess is hang off
the right and the bottom, over its neighbour. The result is read back after
placing and the window is slid to where it still fits. The answer says
`"honored": false` when that happened, so a caller can tell. `fit=center`
answers it too: there, keeping its own size is the point, so the only way to
miss is a window too big for its cell having to be slid to stay on the
workspace.

**A rectangle GlazeWM quietly declines.** `set-floating` applies its own
`--x-pos` and `--width` only while the window has no *custom floating
placement*, and it acquires one the first time anything moves it — an earlier
`/place`, a `Win`+drag, AltSnap. So placing the same window a second time kept
the first placement's size, and the readback then blamed the application for a
minimum size it did not have. Placement is three commands now: `set-floating` to
change the state, then `size` and `position`, neither of which carries that
condition. The same reason is why the daemon centres a popup with
`position --centered` rather than `set-floating --centered=true`.

**A cell too narrow to be a window.** A 5% strip of a 1920px workspace is 96px,
under the 160px floor placement puts on a cell — and growing a rectangle that
was measured from the right edge pushes it past that edge. The floor is applied
first and the cell is then checked against the workspace again.

**Two things placing the same window at once.** Inspecting a new window means
waiting for a subprocess, and a script that launches an application and places
it immediately gets its `/place` in during that wait. The daemon reads the
window's state again before floating it and leaves alone anything that has
stopped being tiled in the meantime — otherwise it would centre the window and
throw the placement away.

**Nonsense fractions.** A missing `fw` arrived as `Number(null)`, which is zero,
so leaving one out asked for a window of negative width. Fractions are now
optional and default to the whole workspace, out-of-range values are clamped
rather than refused, and anything that is not a number is an error with a
reason.

**Gaps that do not match the tiling.** Every side of a placed window used to be
inset by the full gap, so two windows side by side had twice as much air between
them as they had against the screen edge — placed windows never quite lined up
with tiled ones. Now the full gap goes where the cell touches the edge of the
workspace and half a gap on the seam it shares with its neighbour, the two
halves adding up to the one `inner_gap` puts between two tiles.

### Placing a window from a script

```powershell
# the left half of the workspace you are on
$port = Get-Content ~\.glzr\glazewm\bridge-port
Invoke-RestMethod "http://127.0.0.1:$port/place?handle=$hwnd&fx=0&fy=0&fw=0.5&fh=1"
```

| Parameter | Meaning |
|---|---|
| `handle` | the Win32 handle. Required |
| `ws` | workspace name. Optional: the window's own workspace by default, and it is *moved* if it is somewhere else |
| `fx` `fy` `fw` `fh` | the rectangle as fractions of the workspace, 0 to 1. All optional, all defaulting to the whole thing |
| `fit` | `stretch` (default) fills the rectangle, `center` keeps the window's own size |

Fractions rather than pixels so the same call lands correctly on any monitor.
Handles rather than titles because Windows Terminal does not propagate the tab
title to the window title, so several terminals are all called "Terminal" and
cannot be told apart by name — while whatever launched them knows exactly which
one it just created.

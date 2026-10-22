# Mouse

[← back to the README](../README.md)

Hyprland's `bindm` gestures, ported:

```
bindm = SUPER, mouse:272, movewindow      ->  Win + left drag
bindm = SUPER, mouse:273, resizewindow    ->  Win + right drag
```

Both work on **tiled** windows, which is the part AltSnap cannot do.

`glaze-mouse.ahk` also owns [hover focus](#hover-focus), Hyprland's
`follow_mouse`, and the [touchpad swipe](#touchpad-swipe), Hyprland's
`workspace_swipe`.

## Why AltSnap alone is not enough

AltSnap moves a window with `SetWindowPos`. On a tiled window GlazeWM owns the
geometry and puts it straight back, so the window jitters and lands where it
started.

Moving a tiled window means changing its position **in the tree**, not on the
screen. That is a WM command, not a Win32 call. `glaze-mouse.ahk` sends those
commands through the [HTTP bridge](ARCHITECTURE.md#why-there-is-an-http-bridge),
because AutoHotkey v2 has no sockets but does have `WinHttpRequest`.

## How a drag is interpreted

On mouse down the script asks the bridge what is under the cursor:

```
GET /state?x=<mx>&y=<my>&hwnd=<hwnd>
    ->   { found, id, tiling, x, y, width, height, handle }
```

and then behaves differently depending on the answer.

The handle goes along with the point because a rectangle test cannot see the Z
order: two overlapping floating windows are a coin flip, and an always-on-top
overlay is invisible to it. Windows already knows which one is on top, and the
script is on the Windows side. The bridge treats that answer as final, including
its silences — a handle that matches nothing managed means the thing under the
cursor is a bar, a tooltip or a window GlazeWM was told to ignore, and the
honest answer is "nothing", not the tile buried underneath it.

### Tiled, left button

Waits for the release, measures the total displacement, and turns it into a
single direction:

```
direction = |dx| > |dy| ? (dx > 0 ? right : left)
                        : (dy > 0 ? down  : up)
```

then sends `move --direction <direction>`.

Discrete rather than continuous on purpose: moving inside a tree has no
meaningful "halfway", and reshuffling the layout on every pixel of mouse
movement would be unusable. Displacements under 6 px are ignored, so a slightly
sloppy click does not move anything.

### Tiled, right button

Continuous, in steps. Every 28 px of mouse travel is worth one `resize ±4%`, and
the script tracks how many steps it has already applied so the window follows the
cursor instead of running away with every mouse event.

### Floating, either button

Moved and resized directly with `WinMove`. Nothing owns the geometry, so there
is no reason to involve the WM.

## Hover focus

Focus follows the pointer, with no click. GlazeWM has this of its own
(`focus_follows_cursor`), and the config that ships here has it **off**: the
script does it instead, and having both on focuses every hover twice.

The reason for taking it over is a delay. The built-in version moves focus the
instant the pointer touches a window, so crossing a window on the way to another
focuses it in passing — the border flashes, and the
[autotiling daemon](TILING.md) reads the shape of a window you never meant to
touch and sets the split axis from it. The script waits for the pointer to still
be there 90 ms later.

That is the smaller half. The rest is knowing when *not* to focus:

| Situation | Why nothing happens |
|---|---|
| a mouse button is down | it is a drag, a text selection, or a scrollbar being pulled past the edge of its window |
| a menu is open | it closes the moment focus goes elsewhere, and reaching a submenu means travelling over whatever is behind it |
| the window is one a modal dialog has blocked | it is disabled anyway, so reaching past the dialog to it only makes the dialog flash |
| the pointer is on the taskbar, a tooltip, the start menu or task view | not windows you work in |
| the pointer has not left the window it is on | a focus moved with the keyboard is not undone by a cursor sitting still on the previous window |

A modal dialog is recognised by its owner being **disabled** — that is what
makes it modal, and it is the one dependable way to tell one from a window that
merely has an owner. Only the owner chain of the dialog in front is protected,
not the desktop at large: testing "is any modal dialog open" instead means a
Save-As box in one application freezes hover focus on every other window and
every other monitor until it is answered.

Over empty space the workspace under the pointer is focused instead of a window.
That is not a detail: it is what keeps a new window opening on the monitor the
mouse is on, which is the reason for having hover focus at all in a multi-monitor
setup.

### If hover focus does nothing

It rests on GlazeWM being able to focus a window by id, which is
`focus --container-id <id>`. That argument arrived in GlazeWM **3.9.0** — below
the 3.10 this repository asks for anyway, so on a supported install it is there.
Before it, no window could be focused by id over the IPC at all.

Note the shape of that command, because the obvious guess is wrong.
`--container-id` is an argument of `focus` itself, not the `--id` subject prefix
every other command here takes. `focus` is the one command that ignores the
subject — it reads it only for `--direction` — and its argument group is
mandatory, so `command --id <id> focus` does not even parse. Getting that wrong
means hover focus that never works on any version.

The daemon probes rather than assuming, by re-focusing the window that already
has focus, and writes the answer to the log and to `/ping`. The probe runs at
startup and again on the first focus change, because the daemon is normally
launched before there is any window to re-focus.

One failed focus command is never taken as the answer — the window may simply
have closed in the two round trips since the hit test. It takes five failures in
a row, with nothing working in between, and a socket that is down does not count
at all. Nor does the script give up for good when it hears that: it goes quiet
for a minute and tries again, and the daemon asks the question afresh on every
connection to the WM. So a daemon restart, a GlazeWM restart or an upgrade
brings hover focus back on its own.

If the command is missing anyway — a GlazeWM older than this repository
supports, or one that renames it some day — the log says so:

```
this GlazeWM will not focus a window by id (needs 3.9.0 or newer): the mouse
script falls back to activating windows natively, or set focus_follows_cursor:
true in config.yaml for the built-in one
```

and the script keeps hover focus working by **activating the window itself**,
the same route a mouse click takes: GlazeWM watches the foreground window and
follows it. Empty space is the exception and still goes through the bridge,
because focusing the workspace under the pointer is a command that works on
those versions too — so monitor-follows-mouse survives. What is lost is going
through the tree at all, so on an old GlazeWM the tidier answer is the built-in
version: `focus_follows_cursor: true` in
`config.yaml` and `FOCUS_FOLLOWS_MOUSE := false` at the top of
`glaze-mouse.ahk`. That pair is also what to set if you would simply rather have
the built-in one; `FOCUS_NATIVE_FALLBACK := false` turns off the native path
without turning off the rest.

What still works on any version is focusing the **workspace** under the pointer,
because that is an old command. Empty space on another monitor moves focus there
whether or not windows can be focused by id.

### Tuning

| Constant | Default | What it does |
|---|---|---|
| `FOCUS_FOLLOWS_MOUSE` | `true` | hover focus at all |
| `FOCUS_DWELL_MS` | 90 | how long the pointer has to rest on a window |
| `FOCUS_POLL_MS` | 40 | how often the pointer is looked at |
| `FOCUS_SKIP_CLASSES` | shell windows | classes that never take focus by hover |
| `FOCUS_NATIVE_FALLBACK` | `true` | activate windows directly when the WM cannot focus by id |

Raise the dwell if focus still arrives somewhere you were only passing through;
lower it if it feels sticky. Below the poll interval it has no further effect.

## Touchpad swipe

Slide three fingers sideways on the touchpad and the workspace changes. Every
workspace is visited, empty ones included, so you can see the blank ones; set
`TOUCHPAD_SKIP_EMPTY` to get `Alt+[` / `Alt+]` behaviour instead. Fingers moving
left go to the next one, as on Linux.

Windows does not hand multi-finger gestures to applications, but a Precision
Touchpad is a HID device and Raw Input delivers its reports to anyone who
registers for them, focused or not. `glaze-mouse.ahk` registers, reads the
contacts, and works the swipe out itself:

- a frame is a finger count plus an id and a position per finger, possibly
  spread over several reports, so it is only used once every finger has arrived
- positions are fractions of the pad, so the step is the same on any touchpad
- the centre of the fingers has to travel `TOUCHPAD_STEP` sideways for one
  workspace, and then starts over from there, so carrying on sliding keeps going
- mostly vertical movement is ignored: that is Windows' task view
- the first moments after the fingers land are ignored, and turning back
  mid-swipe takes twice the travel: landing and slowing down both wobble

**One thing to do by hand.** Windows still sees the swipe too, and gives it its
own meaning (three fingers switch apps, four switch virtual desktops). Set the
swipe for your finger count to *Nothing* in Settings > Bluetooth & devices >
Touchpad, or both happen at once.

It needs a Precision Touchpad. On an older Synaptics or ELAN driver the device
is not reported this way and nothing happens; `DEBUG_ENABLED` shows whether the
touchpad was recognised.

| Constant | Default | What it does |
|---|---|---|
| `TOUCHPAD_SWIPE` | `true` | turn the whole thing off |
| `TOUCHPAD_FINGERS` | 3 | how many fingers make the swipe |
| `TOUCHPAD_STEP` | 0.15 | fraction of the pad's width for one workspace |
| `TOUCHPAD_INVERT` | `false` | swap the direction |
| `TOUCHPAD_SKIP_EMPTY` | `false` | only visit workspaces that have windows |
| `TOUCHPAD_SETTLE_MS` | 70 | ignore the wobble of fingers landing |
| `TOUCHPAD_COOLDOWN_MS` | 120 | minimum time between two steps |

## Living with AltSnap

The two do not need reconciling, they need a division of labour, and it falls
out of the previous section: floating windows have no owner, so `SetWindowPos`
works and AltSnap handles them fine. Tiled windows have to go through the tree.
The script asks the bridge which kind is under the cursor and picks a lane.

On top of that they use different modifiers — this script on `Win`, AltSnap on
`Alt` — and AltSnap disables itself as soon as it sees an A–Z key, so GlazeWM's
`Alt`+letter bindings keep working.

Nothing about AltSnap is modified for this. The `AltSnap.ini` here is an ordinary
config, included so the split is reproducible rather than because it was tuned.

The shipped `AltSnap.ini` has `Hotkeys=A4 A5` (both Alt keys), left button to
move and right button to resize — the same layout as the `Win` gestures, so the
muscle memory transfers.

AltSnap is entirely optional. Remove it and you lose the extra snapping on
floating windows; everything else is unaffected.

## Tuning

At the top of `glaze-mouse.ahk`:

| Constant | Default | What it does |
|---|---|---|
| `DRAG_THRESHOLD` | 6 | px before a drag counts as one |
| `RESIZE_STEP` | 4 | % per resize step |
| `PX_PER_STEP` | 28 | px of travel worth one step |
| `DEBUG_ENABLED` | false | writes `glaze-mouse.log` on every gesture and hover |

The hover focus constants are in [their own table](#tuning-1).

Turn `DEBUG_ENABLED` on when a gesture does nothing: the log records the point,
the bridge response, which port it resolved to, and whether the window was tiled.
An empty response after a failed re-resolve means the daemon is not running.

A dead bridge is handled differently for hovers than for gestures. A gesture can
afford to spend a moment looking for the daemon again; hover focus would pay
that on every window the pointer crosses, so it backs off instead:

| Answer | Quiet for |
|---|---|
| nothing at all — the daemon is down | 5 s |
| anything that is not an explicit `"ok":true` | 1 s |
| "this GlazeWM cannot focus by id" | 60 s, then it asks again |

Success has to be stated rather than assumed from "something came back". A 404
from an older daemon still holding the bridge port after an upgrade is a
perfectly non-empty answer, and treating it as success marked the window as
dealt with and let hover focus die without a word in the log.

None of those mark the window as dealt with, so the pointer does not have to
leave it and come back for the next attempt to reach it.

The script does not assume the bridge is on 6124. It reads `bridge-port`, falls
back to probing `/ping` on 6124–6127, and re-resolves automatically if a request
comes back empty — so a daemon restart on another port fixes itself.

> **AutoHotkey v2 trap**
> Identifiers are **case-insensitive**, so a variable called `DEBUG` collides
> with a function called `Debug()`, and the script fails to load with
> *"This func cannot be used as an output variable"*. It fails at load time, so
> no hotkeys register and nothing is logged. If the gestures are dead and the log
> is empty, that is the first thing to check.

# Fullscreen games

[← back to the README](../README.md)

## The symptom

Playing a game fullscreen. Switch to another workspace, come back, push the
mouse to the bottom edge — and the auto-hidden taskbar slides up over the game.
It stays that way until you kill and restart `explorer.exe`.

This only happens with the taskbar set to auto-hide. Windows normally suppresses
that reveal while a fullscreen application is in front. The bug is that it
**loses** the suppression.

## The cause

The shell does not track this on a level, it tracks it on an **edge**. It learns
a window is fullscreen when it observes a position change that ends up covering
the whole monitor. Switching workspaces makes the WM hide and show windows, the
tracked state is lost, and since the game never moves again there is no new edge
to remind it.

Restarting `explorer.exe` worked because the shell starts from scratch and
re-evaluates whatever is in front.

## What does not fix it

All of this was measured, not assumed. The test rig: a borderless window
covering the monitor, a workspace switch to break it, then the cursor pushed to
the bottom edge while reading `Shell_TrayWnd`'s rectangle. Hidden reads
`top = 1078`, revealed reads `top = 1032`.

| Attempt | Result |
|---|---|
| `ITaskbarList2::MarkFullscreenWindow(hwnd, TRUE)` | no effect |
| Clearing and setting it again (`FALSE` then `TRUE`) | no effect |
| `SetForegroundWindow` | no effect |
| `SetWindowPos` with `SWP_FRAMECHANGED`, same rectangle | no effect |
| Growing the window 1px and shrinking it back | no effect |
| **Moving the window 1px and putting it back** | **fixes it** |

`MarkFullscreenWindow` is the API that is *supposed* to be the answer, and from
another process it does nothing at all. It is still shipped as a subcommand, so
the next person can rule it out in one command instead of an afternoon.

Growing by a pixel fails and moving by a pixel works for the same reason: growing
never makes the window *stop* covering the monitor, so there is no edge. Moving
it down one pixel uncovers a row, and putting it back covers it again — which is
exactly the transition the shell watches for.

## The fix

On every workspace change the daemon:

1. Waits 300 ms for the WM to finish moving things around.
2. Runs `wm-helpers fix-fullscreen --dry` to see whether anything covers a
   monitor.
3. Skips it if GlazeWM has that window **tiled** — the geometry belongs to the
   WM there, and nudging it behind the WM's back looks like a user drag. That
   case does not exhibit the bug anyway.
4. Otherwise nudges it.

The nudge is a pure move (`SWP_NOSIZE`) on purpose: a resize forces a DirectX
game to recreate its swap chain, a `WM_MOVE` does not.

Detection enumerates top-level windows directly rather than asking GlazeWM,
because the case that breaks is precisely a window GlazeWM does **not** manage —
which is the normal situation for games. Measured both ways: a managed window in
fullscreen state survived the workspace switch, an unmanaged one did not.

To avoid false positives it requires covering the **entire monitor**, not the
work area, so an ordinary maximized window never qualifies. Shell classes
(`Shell_TrayWnd`, `Progman`, `WorkerW`) and bar processes are skipped.

## Verifying it

```powershell
# is anything covering a monitor right now?
~\.glzr\glazewm\wm-helpers.exe fix-fullscreen --dry

# nudge it by hand
~\.glzr\glazewm\wm-helpers.exe fix-fullscreen

# what has the daemon been doing?
Select-String taskbar ~\.glzr\glazewm\autotiling.log | Select-Object -Last 20
```

A working run logs one line per workspace change that needed it:

```
taskbar: nudged Palworld-Win64-Shipping (hwnd 329312) unmanaged
```

If `--dry` reports `"found": false` while a game is in front, Windows does not
consider that window to be covering the monitor. Find out why:

```powershell
~\.glzr\glazewm\wm-helpers.exe classify <hwnd> normal
```

which reports the window's rectangle, the monitor's, whether it has a title bar,
and its best guess at the fullscreen mode: `exclusive`, `borderless`,
`maximized` or `normal`.

## Caveats

Verified with a synthetic borderless window covering the monitor — three
workspace round trips with no reveal, and the daemon logging each nudge. **Not**
verified against true exclusive fullscreen, which changes the display mode
rather than just the window size.

The fix is built to be harmless when it is not needed: with nothing covering a
monitor, it does nothing at all.

# Tiling

[← back to the README](../README.md)

## The problem

GlazeWM splits in one direction until you tell it otherwise. Open four windows
and you get four columns. What komorebi, bspwm and i3's default behaviour give
you instead is a **binary partition**: each new window halves the space of the
one it lands next to, along that space's longer side.

Native BSP has been [requested since 2024](https://github.com/glzr-io/glazewm/issues/678),
opened by the maintainer, tagged `help wanted`, still unimplemented.

## The trick

The same one sway's `autotiling` script uses.

GlazeWM inserts every new window as a **sibling of the focused one**, following
the tiling direction of the parent container. That direction is settable at
runtime. So: before each insertion, set it from the shape of the focused window.

```js
const wanted = focused.width > focused.height ? 'horizontal' : 'vertical';
```

Wide window, split it left/right. Tall window, split it top/bottom. Repeat, and
what falls out is a binary partition of the screen — without patching GlazeWM.

The daemon does this on `focus_changed` and `window_managed`, so the direction is
always correct *before* the next window arrives.

`Alt+J` is still there as a manual override when you want the other axis.

## Rebalancing on close

Closing a window is the harder half. Its sibling absorbs the space, and the
container can be left with a direction that no longer suits its shape — two
windows stacked vertically inside a gap that is now wide and short.

On `window_unmanaged` the daemon walks the container tree and flips any
container whose direction disagrees with its own proportions. No window changes
place: only the axis turns. This is what komorebi does when it rebuilds the BSP.

Two details that matter:

- **One change per pass, re-querying in between.** Changing a container
  recomputes the geometry of everything beneath it, so the children have to be
  judged on the new numbers rather than the stale ones. Six passes maximum,
  which is deeper than any layout anyone actually uses.
- **Only containers with more than one child.** A container with a single child
  has no meaningful direction.

## What it cannot do

**Pseudotiling** — Hyprland's `pseudo`. GlazeWM's tree only knows "this window
fills this rectangle"; there is no notion of a natural size smaller than the
slot. The nearest thing is floating the window with `Alt+F`.

**Changing the direction of existing siblings.** Setting a direction when a
container already has siblings wraps the focused window in a *new* split
container instead of reorienting the existing ones. That is why the layout is
built by setting the direction before insertion, and repaired afterwards by
walking the tree, rather than by rearranging on the fly.

## Watching it work

```powershell
Get-Content ~\.glzr\glazewm\autotiling.log -Wait -Tail 20
```

```
focus_changed: "Terminal" 951x1032 — vertical -> horizontal
window_managed+focus_changed: "Terminal" 951x513 — horizontal -> vertical
rebalance: split vertical -> horizontal
```

Each line is one decision: the event that triggered it, the focused window with
its dimensions, and the direction change. If the layout ever looks wrong, this
tells you what the daemon thought at the time.

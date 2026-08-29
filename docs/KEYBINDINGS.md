# Keybindings

[← back to the README](../README.md) · adding your own: [Customizing](CUSTOMIZING.md)

## Why Alt and not Win

Every tiling WM on Linux uses `Super`. This uses `Alt`, and it is not an
accident:

1. **Windows reserves `Win`+number** for the taskbar. Binding workspaces to
   `Win+1..0` means fighting the shell for every switch.
2. **Remote desktop clients swallow the `Win` key.** AnyDesk never forwards it
   to the host, so on a remote session none of those bindings arrive at all.
3. **Binding `Win+S` eats the plain `s` key.** This one took a while. `Win+S` is
   Windows Search; with it bound in GlazeWM, pressing `s` on its own typed
   nothing, while `Shift+S` worked fine. The tell was that it depended on Shift
   being physically held, not on the letter's case — with Caps Lock on it still
   failed. Something was matching the hotkey pattern and eating the key.

The price of `Alt`: it shadows the classic application menus (`Alt+F` for File,
`Alt+E` for Edit) and `Alt+Enter`, which some games use to toggle fullscreen. If
one gets in your way, change that single binding — nothing else depends on it.

To swap the modifier wholesale, search and replace `alt+` with `win+` in
`config.yaml`, then read points 1 to 3 again.

## Windows

| Key | Action | Hyprland equivalent |
|---|---|---|
| `Alt+Q` | close | `killactive` |
| `Alt+F` | float / unfloat | `togglefloating` |
| `Alt+Shift+F` | float and centre on the workspace | `centerwindow` |
| `Alt+←↑↓→` | move focus | `movefocus` |
| `Alt+Shift+←↑↓→` | move the window in the layout | `movewindow` |
| `Alt+J` | flip the split axis | `togglesplit` |
| `Alt+R` | resize mode: `hjkl` or arrows, `Esc` to leave | a `submap` |

`Alt+J` is a manual override. The [autotiling daemon](TILING.md) normally
decides the split axis for you.

`Alt+Shift+F` is the other manual override: it rescues a floating window that
opened half off the screen or ended up behind something. The daemon does this by
itself to the popups it recognises — see [Popups](POPUPS.md).

It is bound to two commands, `set-floating --shown-on-top=true` and then
`position --centered`, and the second one is the one that does the work.
`set-floating` returns immediately when the window is already floating, which is
the case this binding exists for, and its own `--centered` is ignored once the
window has been moved by hand — which is how it got lost in the first place.

## Workspaces

| Key | Action |
|---|---|
| `Alt+1` … `Alt+0` | go to workspace (`0` is the tenth) |
| `Alt+Shift+1` … `Alt+Shift+0` | send the window there **and follow it** |
| `Alt+[` `Alt+]` | previous / next workspace |

The follow behaviour is two commands chained, `move --workspace N` then
`focus --workspace N`. Stock GlazeWM only does the first: it sends the window
and leaves you behind. komorebi takes you with it, which is what this copies.
Drop the second command if you prefer the stock behaviour.

`Alt+[` and `Alt+]` stand in for Hyprland's `mouse_down` / `mouse_up` workspace
cycling. GlazeWM cannot bind the scroll wheel.

## Launching

| Key | Opens |
|---|---|
| `Alt+S` or `Alt+Enter` | Windows Terminal |
| `Alt+E` | File Explorer |

Deliberately short. A browser, an editor and a launcher are personal choices, so
they live in the region of the config meant for yours — see
[Customizing](CUSTOMIZING.md).

## System

| Key | Action |
|---|---|
| `Alt+Shift+R` | reload the config |
| `Alt+Shift+Ctrl+Esc` | quit GlazeWM |

## Mouse

| Gesture | Action |
|---|---|
| `Win` + left drag | move the window, tiled ones included |
| `Win` + right drag | resize |
| rest the pointer on a window | it takes focus, after 90 ms |
| `Alt` + drag | AltSnap, if you have it installed |

Details and the reasoning in [Mouse](MOUSE.md).

## Windows shortcuts worth leaving alone

| Combination | Why |
|---|---|
| `Win+S` | Windows Search. Binding it eats the plain `s` key, see above |
| `Win+L` | lock screen, not interceptable by anything |
| `Win`+number | Windows taskbar |
| `Alt+Space` | window menu, and the launcher hotkey in many setups |
| `Alt+Tab`, `Alt+F4` | everyone expects these to work |

## Binding modes

`Alt+R` enters the `resize` mode, where the arrows and `hjkl` resize the focused
window with no modifier held. It is GlazeWM's version of a Hyprland `submap`,
declared under `binding_modes` at the top of the config.

To add one of your own, copy the `resize` block, rename it, and bind
`wm-enable-binding-mode --name <yours>` to a key. Always leave a
`wm-disable-binding-mode` inside it or you will be stuck in your own mode.

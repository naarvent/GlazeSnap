# GlazeSnap

A Windows 11 desktop that behaves like a Linux tiling window manager, built on
[GlazeWM](https://github.com/glzr-io/glazewm) and [AltSnap](https://github.com/RamonUnch/AltSnap).

GlazeWM already does the hard part. This fills in the four things that kept
tripping me up after moving over from Hyprland, none of which GlazeWM ships:

| | |
|---|---|
| **BSP layout** | GlazeWM always splits the same way. A small daemon sets the split axis from the shape of the focused window, so the screen partitions like komorebi or bspwm. [How it works](docs/TILING.md) |
| **Mouse gestures on tiled windows** | `Win`+drag to move, `Win`+right-drag to resize, tiled windows included. AltSnap only ever managed floating ones. [How it works](docs/MOUSE.md) |
| **The taskbar over fullscreen games** | Switch workspace, come back, push the mouse down, and an auto-hidden taskbar slides up over your game. Fixed, after finding out that the obvious API for it does nothing. [The whole story](docs/FULLSCREEN-GAMES.md) |
| **Follow the window you just moved** | `Alt+Shift+<n>` sends a window to a workspace *and takes you along*, the way komorebi does. |
| **Dialogs that stay out of the layout** | A "Save as" box does not rearrange your workspace and then rearrange it back. Recognised from the Win32 window style rather than a list of names, because ownership and "cannot be resized" are not things a window rule can match on. [How it works](docs/POPUPS.md) |

New windows also open on whatever monitor and workspace the mouse is on, and
focus follows the cursor — no click needed, and with a short delay so that
crossing a window on the way to another does not focus it in passing.

## Nothing here is patched

No fork of GlazeWM, no patched binary, no injected DLL. GlazeWM is the stock
build from winget and AltSnap runs its own untouched config. Everything above is
a layer on top, driven through GlazeWM's documented IPC — a WebSocket on
`127.0.0.1:6123` that accepts unelevated connections even though the WM itself
runs elevated.

That is what makes each piece possible without touching the source:

- **BSP layout.** GlazeWM inserts every new window as a sibling of the focused
  one, following the parent container's tiling direction — and that direction is
  settable at runtime. Set it from the shape of the focused window *before* the
  next window arrives and the screen partitions binarily. Same trick as sway's
  `autotiling` script.
- **Dragging a tiled window.** AltSnap moves windows with `SetWindowPos`, which
  a tiling WM simply undoes. But a tiled window's position does not live on the
  screen, it lives **in the tree** — so the drag is translated into
  `move --direction` and `resize ±%` commands instead of pixels.
- **Coexisting with AltSnap** is a division of labour rather than a truce.
  Floating windows have no owner, so `SetWindowPos` works and AltSnap keeps
  them on `Alt`. Tiled windows go through the tree, on `Win`. The mouse script
  asks what is under the cursor and picks a lane.
- **Keeping dialogs out of the layout.** GlazeWM's window rules match a name;
  what makes a window a dialog is its style bits and the fact that another
  window owns it, which the IPC does not carry. A tiny C# helper reads them
  straight from Win32 and the daemon floats what it recognises — so it works on
  applications nobody has written a rule for.
- **The taskbar fix** is the one place that calls Win32 directly, and even then
  it is a single `SetWindowPos` on a window we do not own, purely to manufacture
  a state transition the shell is watching for.
- **Following a window to its workspace** is two commands chained in the YAML.
  No code at all.

The glue is an HTTP bridge on port 6124: AutoHotkey v2 has no sockets but does
have `WinHttpRequest`, so the daemon translates HTTP into WebSocket. That port
doubles as a single-instance mutex.

The practical payoff is that GlazeWM updates cannot break this — there is no
patch to rebase and no upstream change to wait for — and nothing runs elevated
except GlazeWM, which already did. Details in [Architecture](docs/ARCHITECTURE.md).

## Install

**Most people:** grab the latest `.msi` from
[Releases](https://github.com/naarvent/glazesnap/releases/latest) and run it.
It installs per-user, no admin rights needed for anything except GlazeWM
itself.

```powershell
winget install glzr-io.glazewm
winget install AutoHotkey.AutoHotkey        # v2, not v1
winget install Microsoft.DotNet.Runtime.10  # optional, for the taskbar fix
winget install AltSnap.AltSnap              # optional, for Alt+drag on floating windows
```

Then run the downloaded `.msi`, and start GlazeWM.

**If you want to customize the source** (edit `autotiling.mjs`,
`glaze-mouse.ahk`, or `config.yaml` and see changes without reinstalling),
clone the repo instead:

```powershell
winget install glzr-io.glazewm
winget install OpenJS.NodeJS            # Node 22 or newer
winget install AutoHotkey.AutoHotkey    # v2, not v1
winget install Microsoft.DotNet.SDK.10  # optional, for the taskbar fix
winget install AltSnap.AltSnap          # optional, for Alt+drag on floating windows

git clone https://github.com/naarvent/glazesnap.git $env:USERPROFILE\glazesnap
cd $env:USERPROFILE\glazesnap
.\install.ps1 -WhatIf   # see what it would do
.\install.ps1           # default: copies files, so updates/git pull won't touch what's installed
```

Editing the source and want changes to apply without reinstalling? Use
`.\install.ps1 -Link` instead — it symlinks the installed files back into
this clone. That mode requires Developer Mode or an elevated shell, and it
skips the config-path rewrite (only a `Write-Warning`), so you'll need to
replace the `USERNAME` placeholder in `config.yaml` by hand.

Then start GlazeWM. AltSnap is optional and installed separately; see
[docs/INSTALL.md](docs/INSTALL.md) for the details, including what to do when
you already have a config you care about.

## Updating

**MSI install:** download the newer `.msi` from
[Releases](https://github.com/naarvent/glazesnap/releases/latest) and run it;
it replaces the previous version in place.

**Clone install:**

```powershell
cd $env:USERPROFILE\glazesnap
git pull
.\install.ps1 -WhatIf   # every file it would touch, without touching any
.\install.ps1
```

Then `Alt+Shift+R` to reload, or restart GlazeWM.

Your settings survive, but only the ones the installer knows how to look for,
and it looks in one place: the regions marked `PERSONAL` in `config.yaml`.

| | |
|---|---|
| Bindings inside `PERSONAL: keybindings`, and the `startup` and `shutdown` regions | **carried over** into the incoming config |
| A file of your own the repo does not ship — your own `.ahk`, say | **untouched**. The installer copies what it brings and deletes nothing |
| Anything else in `config.yaml`: gaps, borders, `window_rules`, bindings written outside the region | **replaced**, with the old file kept as `config.yaml.bak` |
| `glaze-mouse.ahk`, `autotiling.mjs`, `AltSnap.ini`, including the constants at the top of each | **replaced**, each with its own `.bak` |

Two things worth knowing about those backups: a `.bak` holds the *previous*
version only, since the next install overwrites it; and once you have installed
with `-Link` there are no backups at all, because the installed files are then
symlinks into this clone and `git pull` edits them directly.

So the arrangement that survives updates without thinking about it is: your
bindings inside the `PERSONAL` region, and your AutoHotkey macros in a script of
your own launched from `PERSONAL: startup`, rather than added to
`glaze-mouse.ahk`. [Customizing](docs/CUSTOMIZING.md) has the details.

## Keys

`Alt` is the modifier, not `Win`. There are three good reasons and one of them
cost an afternoon of debugging — [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md) has
the full list and the story.

The short version:

| | |
|---|---|
| `Alt+Q` `Alt+F` | close, float |
| `Alt+Shift+F` | centre a floating window that landed badly |
| `Alt+E` `Alt+S` | file manager, terminal |
| `Alt+←↑↓→` | move focus |
| `Alt+Shift+←↑↓→` | move the window |
| `Alt+1…0` | switch workspace |
| `Alt+Shift+1…0` | send the window there and follow it |
| `Alt+R` | resize mode |
| `Win`+drag | move / resize with the mouse |

Adding your own goes in a marked region of the config that upgrades never
overwrite: [docs/CUSTOMIZING.md](docs/CUSTOMIZING.md).

## Documentation

| | |
|---|---|
| [Install](docs/INSTALL.md) | requirements, what goes where, symlink mode |
| [Keybindings](docs/KEYBINDINGS.md) | every binding, and why the modifier is Alt |
| [Customizing](docs/CUSTOMIZING.md) | your own bindings, modes and startup commands |
| [Architecture](docs/ARCHITECTURE.md) | the moving parts and how they talk |
| [Tiling](docs/TILING.md) | how the BSP layout is emulated |
| [Popups](docs/POPUPS.md) | dialogs, and where a window ends up |
| [Mouse](docs/MOUSE.md) | the drag gestures, hover focus, and living with AltSnap |
| [Fullscreen games](docs/FULLSCREEN-GAMES.md) | the taskbar bug, measured and fixed |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | when something stops working |

## What is in here

```
glazewm/
  config.yaml       GlazeWM configuration
  autotiling.mjs    the daemon: BSP, HTTP bridge, taskbar fix
  autotiling.vbs    launches it without a console window
  glaze-mouse.ahk   Win+drag gestures
  wm-helpers/       C# helper for the parts that need the Win32 window API
altsnap/
  AltSnap.ini       Alt+drag. An ordinary AltSnap config, unmodified, here so
                    the split of labour is reproducible
install.ps1         install and build
sync.ps1            pull your live config back into the repo
```

No dependencies beyond the four programs above: the daemon is plain Node with
the global `WebSocket`, and the helper is a single C# file.

## License

[MIT](LICENSE).

# Customizing

[← back to the README](../README.md) · what ships by default: [Keybindings](KEYBINDINGS.md)

Everything in `config.yaml` is yours to edit. This page is about the parts that
survive a reinstall, and how to write a binding without hitting the sharp edges.

## Where your settings go

GlazeWM has no `include` mechanism: `config.yaml` is a single file. So the split
between "the setup" and "your stuff" is marked inside the file itself:

```yaml
  # >>>>>> PERSONAL: keybindings >>>>>>
  - commands: ['shell-exec C:\PROGRA~1\MOZILL~1\firefox.exe']
    bindings: ['alt+b']
  # <<<<<< PERSONAL <<<<<<
```

There are three of these regions:

| Region | What belongs in it |
|---|---|
| `PERSONAL: startup` | extra `startup_commands`: a status bar, a wallpaper engine, a tray app |
| `PERSONAL: shutdown` | `shutdown_commands` |
| `PERSONAL: keybindings` | your own bindings |

They are protected in both directions:

- **`install.ps1`** carries over whatever you already had, so reinstalling or
  pulling an update never flattens your bindings.
- **`sync.ps1`** swaps them back for the templates when pulling your live config
  into the repo, so a pull request or a fork never publishes your paths.

Edit outside those regions freely. You only lose those changes if you reinstall
over the top, and `install.ps1` leaves a `.bak` when it does.

## Writing a binding

```yaml
  - commands: ['<command>']
    bindings: ['<key>']
```

Both are lists. Several commands run in order; several keys do the same thing.

### A worked example

Firefox on `Alt+B`, VS Code on `Alt+C`, and `Alt+G` to jump to workspace 5 and
float whatever is focused there:

```yaml
  # >>>>>> PERSONAL: keybindings >>>>>>
  - commands: ['shell-exec C:\PROGRA~1\MOZILL~1\firefox.exe']
    bindings: ['alt+b']

  - commands: ['shell-exec code']
    bindings: ['alt+c']

  - commands: ['focus --workspace 5', 'toggle-floating']
    bindings: ['alt+g']
  # <<<<<< PERSONAL <<<<<<
```

Save, press `Alt+Shift+R`. If a new binding does nothing, check
`~\.glzr\glazewm\errors.log` first: a config that fails to parse is **not
applied at all**, so one typo silently reverts every change in the file.

### Paths with spaces

`shell-exec` does not accept paths containing spaces, quoted or not. Use the 8.3
short path:

```cmd
for %I in ("C:\Program Files\Mozilla Firefox\firefox.exe") do @echo %~sI
```

which prints something like `C:\PROGRA~1\MOZILL~1\firefox.exe`. That is what
goes in `commands`.

Anything on your `PATH` sidesteps the problem entirely: `shell-exec code`,
`shell-exec wt`, `shell-exec explorer`.

### Key names

Letters and digits as themselves. Modifiers `alt`, `shift`, `ctrl`, `win`,
joined with `+`. Named keys: `enter`, `escape`, `space`, `tab`, `backspace`,
`delete`, `left`, `right`, `up`, `down`, `bracketleft`, `bracketright`, `comma`,
`period`, `f1`–`f12`.

Combinations Windows will not give you are listed in
[Keybindings](KEYBINDINGS.md#windows-shortcuts-worth-leaving-alone).

### Commands worth knowing

| Command | Does |
|---|---|
| `shell-exec <program>` | launches something |
| `close` | closes the focused window |
| `toggle-floating` | float / unfloat |
| `toggle-tiling-direction` | flips the split axis |
| `focus --direction <left\|right\|up\|down>` | moves focus |
| `focus --workspace <n>` | jumps to a workspace |
| `focus --next-active-workspace` | next non-empty workspace |
| `move --direction <left\|right\|up\|down>` | moves the window in the layout |
| `move --workspace <n>` | sends the window elsewhere |
| `resize --width <±n%>` / `--height` | resizes |
| `set-floating` / `set-tiling` / `set-fullscreen` | forces a state |
| `wm-enable-binding-mode --name <mode>` | enters a mode |
| `wm-reload-config` | reloads |

`glazewm command --help` has the rest.

## Startup commands

The two entries outside the `PERSONAL: startup` region are load-bearing: they
start the [daemon](ARCHITECTURE.md) and the [mouse script](MOUSE.md). Add your
own inside the region:

```yaml
    # >>>>>> PERSONAL: startup >>>>>>
    - 'shell-exec C:\PROGRA~1\YASB\yasbc.exe start'
    # <<<<<< PERSONAL <<<<<<
```

Same 8.3 path rule applies.

## Gaps, borders, rules

Ordinary GlazeWM configuration, all in `config.yaml` and commented inline:

- `gaps.inner_gap` / `outer_gap` — `outer_gap.top` is `0` because a status bar
  registered as a Windows app bar already reserves its strip of the work area.
  If your bar does not reserve work area (Zebar does not), put its height there.
- `window_effects` — the border colour on the focused window.
- `window_rules` — applications that misbehave when tiled. The shipped list
  covers PowerToys, Office and picture-in-picture windows. Add yours with
  `commands: ['ignore']` and a `window_process` or `window_class` match. The
  rule below them floats the dialog classes instead of tiling them.

To find the process or class name of a stubborn window:

```powershell
~\.glzr\glazewm\wm-helpers.exe classify <hwnd> normal   # how it is fullscreen
~\.glzr\glazewm\wm-helpers.exe inspect <hwnd>           # class, owner, style bits
```

Which windows are floated automatically is not a window rule — it is the
`POPUPS` block at the top of `autotiling.mjs`, because the decision is made from
Win32 style bits a rule cannot match on. `neverFloat` and `alwaysFloat` there
take process names. See [Popups](POPUPS.md#policy-lives-in-the-daemon).

## Keeping a fork in sync

```powershell
.\sync.ps1     # live config -> repo, personal regions stripped
git diff
git commit -am "..."
```

`sync.ps1` also replaces your Windows user name with `USERNAME`; `install.ps1`
substitutes the real one back on whatever machine it runs on.

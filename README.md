<p align="center">
  <img src="assets/omara.png" alt="Omara" width="180">
</p>

<h1 align="center">Omara</h1>

<p align="center"><strong>Switch your entire desktop into the way you work.</strong></p>

A *mode* is a way your desktop is set up. Coding, Gaming, Deep Work, whatever
you actually do. Pick one and Omarchy becomes that: your apps open on the
workspaces you want them on, notifications behave, audio goes where it should,
and you land exactly where you meant to start.

```
Coding                          Deep Work
  Ghostty        ws 1             Do Not Disturb    on
  Firefox        ws 2             Theme             gruvbox
  Slack          ws 3             Workspace         3
  Do Not Disturb off              Everything else   left alone
  Land on        ws 1
```

One click, or `omara activate coding`.

Local-first. No account, no cloud, no telemetry, no network access. Omara
ships **empty**: nothing exists until you make it.

---

## Contents

- [What it does](#what-it-does)
- [What it is not](#what-it-is-not)
- [Install](#install)
  - [Requirements](#requirements)
  - [From git](#from-git)
  - [From a local copy](#from-a-local-copy)
  - [Update](#update) · [Uninstall](#uninstall)
  - [Where things live](#where-things-live)
- [Quick start](#quick-start)
- [Building a mode](#building-a-mode)
  - [Capture the desktop](#capture-the-desktop)
  - [Applications](#applications)
  - [Icons](#icons)
  - [Workspaces](#workspaces)
  - [Environment](#environment)
  - [Commands](#commands)
- [Automatic triggers](#automatic-triggers)
- [Turning a mode off](#turning-a-mode-off)
- [The windows already on screen](#the-windows-already-on-screen)
- [Keybindings](#keybindings)
- [Command line](#command-line)
- [Import and export](#import-and-export)
- [Settings](#settings)
- [Config file](#config-file)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

---

## What it does

Activating a mode can, in this order:

| | |
|---|---|
| **Notifications** | Turn Do Not Disturb on, off, or leave it alone |
| **Audio** | Switch the default output device |
| **Wallpaper** | Set it, via Omarchy's own background command |
| **Theme** | Switch it, via `omarchy theme set` |
| **Workspace** | Focus the workspace the mode leaves you on |
| **Windows** | Offer to close what is already open, gracefully, never killed |
| **Applications** | Open them, each on the workspace you chose for it |
| **Commands** | Run your own `onActivate` shell hooks |

Nothing is mandatory. Every field has a "leave it alone" state and that is the
default, so a mode that only sets a workspace changes only the workspace.

Nothing aborts either: a missing app or an unplugged headset is a warning, the
rest of the mode still applies, and you get one summary notification, never
one per action.

## What it is not

**A session manager.** Omara does not save or restore window layouts, and it
never will. Tools that snapshot your Hyprland windows already do that job, and
Omara is built to sit alongside one.

| A session manager restores | A mode changes |
|---|---|
| which windows were open | how the desktop behaves |
| where they were placed | what is allowed to interrupt you |
| what they were showing | where sound goes, what starts, where you land |

---

## Install

### Requirements

| | |
|---|---|
| Omarchy | 4.0 (Quattro) or newer |
| Everything else | already on your system: Quickshell, Hyprland, PipeWire, `jq` |

Omara installs nothing, pulls no dependencies, and makes no network request
after the clone.

Check you are on a new enough Omarchy:

```bash
omarchy plugin list >/dev/null && echo "plugin support: ok"
```

### From git

```bash
omarchy plugin add https://github.com/anishfn/omara.git
omarchy plugin enable anishfn.omara --section left
```

Plugins land **disabled**, on purpose: a plugin is code that runs inside your
shell, so `add` and `enable` are two steps and the gap between them is for
reading it.

```bash
omarchy plugin add https://github.com/anishfn/omara.git
$EDITOR ~/.config/omarchy/plugins/anishfn.omara     # read it
omarchy plugin enable anishfn.omara --section left  # then run it
```

`--section` takes `left`, `center`, or `right`. To put the widget next to
something specific instead:

```bash
omarchy plugin enable anishfn.omara --section right --before omarchy.clock
```

### From a local copy

No git remote needed. Any folder named after the plugin id under
`~/.config/omarchy/plugins/` is discovered:

```bash
git clone https://github.com/anishfn/omara.git
cp -r omara ~/.config/omarchy/plugins/anishfn.omara
omarchy plugin enable anishfn.omara --section left
```

### Check it worked

```bash
omarchy plugin list | grep modes
# anishfn.omara   enabled   third-party   bar-widget,service   Omara
```

The widget appears in your bar immediately, reading `○ No mode`. If it does
not, see [Troubleshooting](#troubleshooting).

### Optional: the CLI on your `PATH`

The plugin ships a CLI. Symlink it if you want to drive modes from scripts or
keybindings:

```bash
mkdir -p ~/.local/bin
ln -sf ~/.config/omarchy/plugins/anishfn.omara/bin/omara \
  ~/.local/bin/omara
omara status
```

Everything it does is also reachable without it, through
`omarchy-shell modes <method>`.

### Update

```bash
omarchy plugin update anishfn.omara
```

Your modes live outside the plugin folder, so an update never touches them.

### Uninstall

```bash
omarchy plugin remove anishfn.omara
```

That removes the plugin and its bar placement. Your modes are left behind in
case you come back. To go the rest of the way:

```bash
rm ~/.config/omarchy/omara.json
rm ~/.local/state/omarchy/omara-state.json
rm -f ~/.local/bin/omara
```

Removing the plugin does **not** put back a wallpaper, theme, audio output, or
Do Not Disturb state a mode set. Run *Disable mode* first if you want the
desktop back the way it was.

### Where things live

| Path | What |
|---|---|
| `~/.config/omarchy/plugins/anishfn.omara/` | the plugin itself |
| `~/.config/omarchy/omara.json` | your modes, safe to version-control |
| `~/.local/state/omarchy/omara-state.json` | what to put back on *Disable mode* |

Those three are the only paths Omara writes.

---

## Quick start

1. **Click the widget** in your bar. On first run it reads `○ No mode`.
   There are no modes until you make one.
2. **Create a mode.** Fastest way: set your desktop up the way you like it,
   then pick **Current desktop**, which captures what is open, where, and how.
   Otherwise pick **Blank** and fill it in yourself. Nothing is preloaded.
3. **Add applications.** *Add application* opens a searchable list of everything
   installed. Type, arrow, Enter.
4. **Give each app a workspace.** The small `ws` box on each row. Terminal on 1,
   browser on 2, chat on 3.
5. **Set where you land.** The *Workspace* field further down is the workspace
   the mode leaves you on.
6. **Set the mood.** Under *Environment*: Do Not Disturb, audio output,
   wallpaper, and **Theme**, each picked from a list rather than typed.
7. **Save**, then click the mode in the bar popup. If windows are already
   open, Omara asks whether to close them first.

Your apps open across their workspaces without the screen flicking through each
one, and you end up on the workspace you chose.

---

## Building a mode

Right-click the bar widget, or run `omara manage`.

The left pane lists your modes, the right pane edits the selected one.
Nothing is written until you press **Save**, and leaving with unsaved changes
asks first, so nothing is lost by accident.

Renaming a mode keeps its `id`, so keybindings and scripts keep working.
**Duplicate** copies the whole mode when you want a variant of one you
already have. Hovering a row in either list reveals arrows to reorder it.

| Shortcut | |
|---|---|
| `Tab` | Jump into the form, then move field to field |
| `Ctrl+S` | Save |
| `Ctrl+N` | New mode |
| `Ctrl+D` | Duplicate the selected mode |
| `Alt+↑` / `Alt+↓` | Move the selected mode up or down |
| `Esc` | Close, or back out of a picker |

### Capture the desktop

**Capture desktop** turns what you have right now into a mode, with no
typing. It records:

- every open window, matched to its installed application, with the workspace it is on
- the workspace you are looking at, as where the mode leaves you
- the current Do Not Disturb state, audio output, wallpaper, and theme

The editor opens on the result straight away, because a capture is a starting
point rather than a finished mode. Two Firefox windows on two workspaces
capture as two rows, so delete the one you did not mean. If the current wallpaper
or Do Not Disturb state is not something you want this mode forcing, set
those fields back to *Leave unchanged*.

From the command line:

```bash
omara capture "Right now"
```

### Applications

![Adding an application](screenshots/app-picker.png)

**Add application** opens a searchable list drawn from the same desktop-entry
index the Omarchy launcher uses, so you get the same names, icons, and
sorting. Apps
added this way are stored as a desktop id and launched exactly the way the
launcher launches them.

**Custom command** is the escape hatch for what a `.desktop` file cannot say:

```
chromium --new-window https://github.com
ghostty -e btop
omarchy-launch-terminal
```

Both kinds sit in one list, each with its own on/off switch, which is handy for
keeping
an app in a mode without launching it every time.

### Icons

![Choosing an icon](screenshots/icon-picker.png)

The icon box next to the name opens a searchable grid. Search by what you are
doing (`code`, `game`, `focus`, `music`, `terminal`) or browse. **No icon** is
always there.

The set is drawn from the glyphs Omarchy's own menu ships, so everything in the
grid is guaranteed to render in your font rather than showing up as an empty
box.

### Workspaces

A mode can lay out as many workspaces as you need.

**Per application:** the `ws` box on each row. Blank means "wherever I am".
Anything else opens that app on that workspace, using Hyprland's own placement
rules, so nothing drags your focus around while a mode starts up. Named
workspaces work as well as numbers.

**For the mode:** the *Workspace* field is simply where you are left once
everything is running. Leave it blank to stay put.

So a Coding mode might be:

| | |
|---|---|
| Ghostty | ws `1` |
| Firefox | ws `2` |
| Slack | ws `3` |
| Workspace | `1` |

Three workspaces populated, and you start on the terminal.

### Environment

| Field | Options |
|---|---|
| **Notifications** | Leave unchanged, Do Not Disturb on, or Do Not Disturb off |
| **Audio output** | Leave unchanged, or any output PipeWire can see |
| **Wallpaper** | A path, or **Browse** for a file chooser |
| **Theme** | Picked from a list of your installed themes |

An audio device that is not plugged in right now still appears in the list,
marked *(not connected)*, so a mode never quietly forgets which headset it
was pointing at.

The **Theme** button opens a searchable list of every theme on the machine,
both the ones Omarchy ships and the ones you installed into
`~/.config/omarchy/themes/`. A mode stores the same slug Omarchy writes to
`theme.name`, so a captured theme and a picked one are the same value. *Leave
unchanged* is always at the top right.

### Commands

Under **Advanced**. `onActivate` runs when the mode switches on,
`onDeactivate` when it switches off. These are shell strings, so pipelines and
redirects work. That is the reason to write one instead of adding an
application.

Omara does not guess at inverses. If a command changes something you want put
back, write the inverse yourself:

```
On activate     omarchy-toggle-idle stay-awake
On deactivate   omarchy-toggle-idle allow-idle
```

---

## Automatic triggers

**Off by default.** Turn them on under *Settings*.

A trigger watches for a window class opening and offers to switch:

```
Switch to Gaming?
steam, click to switch
```

It is a notification with a click action rather than a dialog. A window stealing
your focus is exactly the interruption a mode switch is meant to prevent.
Click to switch, or ignore it.

Per trigger you can pick **Ask**, **Switch** (no prompt), or **Default** (follow
the global *Ask before switching* setting).

Find the class an app actually reports with:

```bash
hyprctl clients -j | jq -r '.[].class'
```

**Loop prevention.** Gaming launches Steam; Steam opening is what the Gaming
trigger watches for. Three rules break that:

1. a trigger for the mode that is already active is ignored
2. any trigger within 8 seconds of an activation is ignored
3. a disabled trigger or mode never fires

---

## Turning a mode off

*Disable mode* is not *reset to factory defaults*. It puts back the values
**this plugin** changed, to what they were before it changed them, and only
while what is on screen is still what the plugin set. Anything you changed by
hand since is yours and is left alone.

Switching straight from Coding to Gaming does the same thing: Coding's
`onDeactivate` runs, then Gaming applies.

---

## The windows already on screen

A mode opens its own applications, so switching into one on top of a full
desktop leaves you with both. When you click a mode and something is open,
Omara asks first:

- **Close them** closes every open window, then activates the mode. The
  close is the same request the compositor sends when you hit a window's close
  button, so anything with unsaved work still gets to put up its own prompt.
  Nothing is killed.
- **Keep them** activates the mode on top of what is already there.
- **Cancel** does nothing.

Turn the question off under *Settings → Ask about open windows*, and switching
always keeps what is open.

The question is a click-only thing. Automatic triggers, the shell restart
restore, and the CLI never wait on a dialog: they keep your windows unless you
say otherwise with `omara activate <id> --close`.

---

## Keybindings

Omara registers no shortcuts. Add what you like to your Hyprland config:

```
bindd = SUPER, C, Omara, exec, omara menu
bindd = SUPER SHIFT, C, Coding mode, exec, omara activate coding
bindd = SUPER ALT, C, Manage modes, exec, omara manage
```

Without the CLI on your `PATH`, go through the shell directly:

```
bindd = SUPER, C, Omara, exec, omarchy-shell shell toggle anishfn.omara
```

---

## Command line

```
omara list              every mode, as JSON
omara names             ids, one per line
omara current           the active id, empty if none
omara status            one-line summary
omara activate <id> [--close|--keep]
omara deactivate
omara capture [name]    make a mode from the desktop as it is
omara menu              open the bar popup
omara manage            open the manage panel
omara close             close the manage panel
omara edit <id>
omara log               what recent activations did
omara export [id]       export document on stdout
omara reload            re-read the config file
```

`log` is the detail behind the summary notification:

```
$ omara log
      Activating Coding
      Workspace → 1
      Launched Ghostty on workspace 1
      Launched Firefox on workspace 2
WARN  "slack" is not installed; skipped
WARN  Activated Coding with 1 warning(s)
```

---

## Import and export

**Export** writes `omara-export.json` to a folder you pick, or prints one
mode to stdout:

```bash
omara export gaming > gaming.json
```

**Import** previews the file first and warns when the incoming modes carry
applications or commands, because activating one will run them as you. If an id
already exists you choose **Create copy**, the only option that cannot lose what
you already have, or **Replace existing**.

---

## Settings

| Setting | Default | What it does |
|---|---|---|
| Launch applications | on | A mode may start the apps it lists |
| Show a notification | on | One summary per switch |
| Automatic triggers | **off** | Watch for applications at all |
| Ask before switching | on | A trigger asks first unless it says otherwise |
| Ask about open windows | on | Offer to close what is open before switching |
| Restore after shell restart | **off** | Reapply the active mode on startup |

*Restore after shell restart* replays **settings only**: notifications, audio,
wallpaper, theme, and workspace. It never relaunches applications or reruns
commands: Quickshell restarts more often than you would think, and a reload that
reopens six windows is hostile.

---

## Config file

Everything lives in `~/.config/omarchy/omara.json`:

```json
{
  "version": 1,
  "activeMode": "coding",
  "behavior": {
    "confirmAutomaticSwitch": true,
    "confirmWindowsOnSwitch": true,
    "showNotifications": true,
    "launchApps": true,
    "triggersEnabled": false,
    "restoreOnStart": false
  },
  "ui": { "showIcon": true, "showName": true },
  "modes": [
    {
      "id": "coding",
      "name": "Coding",
      "icon": "󰵮",
      "description": "Development environment",
      "enabled": true,
      "appearance": { "wallpaper": null, "theme": null },
      "notifications": { "dnd": false },
      "audio": { "output": null },
      "workspaces": { "target": 1 },
      "applications": [
        { "desktopId": "com.mitchellh.ghostty", "workspace": 1, "enabled": true },
        { "command": "chromium --new-window https://github.com", "workspace": 2, "enabled": true }
      ],
      "commands": { "onActivate": [], "onDeactivate": [] },
      "triggers": [
        { "type": "application", "value": "steam", "enabled": true, "behavior": "ask" }
      ]
    }
  ]
}
```

`null` means *leave it alone* everywhere it appears. `"dnd": false` is a
different instruction from `"dnd": null`. The first turns Do Not Disturb off,
the second does not touch it.

An application has either a `desktopId` or a `command`, never both. `workspace`
is optional on each.

Editing the file by hand works; the plugin watches it and reloads live. Replace
it wholesale (a dotfiles `git checkout`, a restored backup) and the change is
picked up within a minute, or immediately with `omara reload`.

---

## Security

Omara runs unsandboxed inside `omarchy-shell`, like every Omarchy plugin.
Precisely what that means here:

**It never** makes a network request, downloads or evaluates code from anywhere,
collects telemetry, runs anything on install or import, writes outside
`~/.config/omarchy/omara.json` and
`~/.local/state/omarchy/omara-state.json`, or asks for elevated privileges.

**It does run programs, but only the ones you configured:**

- **Picked applications** are stored as a desktop id and handed to the shell's
  own launcher. Nothing in the mode is interpreted as a command; the
  `.desktop` file already on your system decides what runs.
- **Custom commands** are tokenized like a shell would (quotes honoured) and run
  as an argv vector through `exec "$@"`. Every token stays one positional
  parameter, so a filename, URL, or `$(...)` inside an argument is literal data
  and can never become a second command.
- **`onActivate` / `onDeactivate`** *are* shell strings, deliberately. They run
  as you, through your login shell, exactly like a line in your own dotfiles.
  Treat them that way.

**Importing is the only place untrusted data arrives.** An imported file is
parsed, normalized, and previewed, never applied on sight, and the preview names
every mode carrying something executable. Nothing runs until you activate
that mode.

Found a problem? Open an issue describing the class of issue, not a working
exploit.

---

## Troubleshooting

**The widget is not in my bar.** `omarchy plugin list` should show
`anishfn.omara` enabled. If not:
`omarchy plugin enable anishfn.omara --section left`.

**The CLI says the plugin is not enabled.** It talks to the running shell. Check
`omarchy-shell shell ping`, then that the plugin is enabled.

**A mode did not do everything.** `omara log`, or the *Activity*
tab in the manage panel. A missing executable, an unplugged device, or an
unreadable wallpaper is a warning; the rest of the mode still applied.

**A captured app is listed twice.** You had two of its windows open, on two
workspaces. Delete the row you do not want.

**A captured window became a raw command instead of an app.** Its window class
did not match any desktop entry. The command is the lowercased class and usually
works; if not, delete it and add the app from the picker.

**An app opened on the wrong workspace.** Its `ws` box is blank, so it opened
wherever you were. Fill it in.

**An application shows "(not installed)".** The mode names a desktop entry
that is no longer on this machine, usually an imported mode or an app you
removed. The row is kept so you can see what it pointed at.

**My audio device says "(not connected)".** The device is not present right now.
Plug it in and activate again; the mode is not rewritten.

**The wallpaper chooser seems to do nothing.** The editor unmaps itself while an
external chooser is open. A layer-shell overlay sits above every window, so the
dialog would otherwise open behind it. If the chooser fails to start at all,
`omara log` records the exit code.

**I edited omara.json and nothing happened.** `omara reload`. If
the file could not be parsed, a copy was saved as `omara.json.corrupt` and
the plugin started from defaults rather than overwriting your only copy.

**The theme list is empty.** Omara reads `$OMARCHY_PATH/themes` and
`~/.config/omarchy/themes`. If `omarchy theme list` prints themes and the picker
does not, `omarchy-restart-shell`.

**I am never asked about my open windows.** Either nothing is open, or
*Settings → Ask about open windows* is off. The question is also skipped on
purpose for triggers, the startup restore, and the CLI.

**Nothing switches when I open Steam.** Triggers are off by default. Turn them
on under *Settings*, and check the class matches what
`hyprctl clients -j | jq -r '.[].class'` reports.

---

## Development

```bash
git clone https://github.com/anishfn/omara.git
cd omara
node --test tests/          # pure-logic unit tests, no desktop needed
omarchy plugin validate .   # the same checks the shell enforces
```

The tests need nothing but `node`. They cover the schema, activation and
restore plans, argv tokenization, import/export, triggers, and capture, and
they also read the QML as text to pin the invariants that are easy to break by
accident: the unsaved-changes guard, the suspend-and-resume contract around
external choosers, the IPC methods the CLI calls, and that every icon comes
from the shared glyph map.

To iterate against a live shell, work in
`~/.config/omarchy/plugins/anishfn.omara/`, where saving any file reloads the
plugin. QML is cached on disk, so if a stale compile error keeps reappearing
after you fixed it, `omarchy-restart-shell` clears it.

| File | What it is |
|---|---|
| `Model.js` | Schema, activation plans, triggers, import/export. No Qt and no Quickshell, which is why node can test it. |
| `Service.qml` | Config file, runtime snapshot, activation, triggers, the `omara` IPC target, and the editor window. |
| `BarWidget.qml` | Bar button and switcher popup. |
| `ModeRow.qml` | One mode in a list. |
| `EditorWindow.qml` | The manage / edit overlay. |
| `ModeForm.qml` | The edit form for one mode. |
| `AppPicker.qml` | Installed-application picker, backed by the shell's `AppLibrary`. |
| `IconPicker.qml` | Glyph grid for the mode icon, backed by `icons.json`. |
| `ThemePicker.qml` | Installed-theme picker, shipped themes and your own. |
| `PromptDialog.qml` | Modal with more than two answers, which `ConfirmDialog` cannot do. |
| `SwitchDialog.qml` | The close-or-keep question, in its own overlay window. |
| `icons.json` | Curated Nerd Font glyphs with search keywords. |
| `bin/omara` | CLI over the `omara` IPC target. |

The shell instantiates a `service` plugin exactly once per session, which is
what makes "the active mode" one answer rather than one per monitor.

Two rules worth knowing before changing anything:

- **Icons come from `Model.Glyph`, never a literal.** A codepoint can be in a
  font's `cmap` and still paint a filled box, so a new glyph gets checked
  against the font `monospace` actually resolves to before it ships.
- **`activating` must always come back down.** Activation is wrapped in
  `try/finally`; a stuck flag refuses every future switch.

---

## License

MIT. See [LICENSE](LICENSE).

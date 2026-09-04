# Known bugs

One left. Everything below the line is what this file used to list, kept with
what was done about each, because the reasoning is worth more than the tick.

---

### 0. An open overlay collects keystrokes meant for other windows

`EditorWindow.qml`, `SwitchDialog.qml` — `WlrLayershell.keyboardFocus`

A panel left open while you work elsewhere is delivered your typing, and
Enter, Space or Ctrl+N on it is enough to create or delete a mode you never
touched. Observed three times: a mode created beside an identical one, and on
another occasion every mode in the config gone.

**Still open.** Both overlays prime with `Exclusive` and settle on `OnDemand`,
matching the shell's own `KeyboardPanel`. That is strictly more correct —
`Exclusive` also routes every *pointer* event compositor-wide — but it does not
fix this. Measured, with the prime confirmed firing and the surface confirmed
on `OnDemand`: focus another window with `hyprctl dispatch focuswindow`, press
Escape, and the editor still closes. The keys still reach it.

The reason looks structural rather than a wrong flag. This is a full-screen
overlay on `WlrLayer.Overlay` holding a dismissal scrim, so there is no way to
click another window without dismissing it, and Hyprland does not appear to
move keyboard focus off a layer surface for a window-focus dispatch. `OnDemand`
buys what it can; the surface still owns the keyboard because nothing can take
it away without closing the panel.

What would actually fix it is still unresolved, and every candidate is a design
change rather than a flag: close on focus loss, if Quickshell ever surfaces such
a signal for a layer shell; drop the full-screen scrim so the panel is only as
big as its card and other windows stay clickable, losing click-outside-to-close
with it.

**What is in place is the third candidate, the one that is not a design
change.** `root.engaged` is false until the pointer has *moved* over the panel
— movement, not merely resting under it, so a panel that opened beneath a
stationary cursor does not count — and `Ctrl+N`, `Ctrl+D` and `Alt+Up/Down` do
nothing until it is true. Those are the three shortcuts that can invent or
destroy a mode, and they are what every observed instance came through. Escape
and `Ctrl+S` stay live: neither can create anything, and being unable to close
a panel that has stolen your keyboard would be worse than the bug.

That is a mitigation. The panel still receives your typing, and the practical
advice has not changed: do not leave it open. Every observed instance came from
the panel being opened programmatically while someone was using the machine,
not from ordinary use.

---

## Fixed

### 1. `deactivate` could run in the middle of an activation

`Service.qml` — `deactivateMode()`

`activateMode` refused to start while `activating` was true; `deactivateMode`
had no such guard, and both the bar's *Disable mode* button and `omara
deactivate` reached it directly. During the environment probe (up to 10s) a
deactivation could run `restorePlan` against `previousState`, clear the
snapshot, and set `activeMode` to null — and then the activation still in
flight applied its own settings and wrote itself back as active. The desktop
ended up in the new mode with an empty restore snapshot.

Fixed: `deactivateMode` takes the same `activating` guard and says so in the
log. The IPC verb answers `busy` rather than `error`, which is what `capture`
already did.

### 2. A hung file chooser left the editor invisible with no way back

`EditorWindow.qml` — `suspendFor()`, `chooserCommand()`

The three chooser launches ran `omarchy-file-select` unbounded and set
`root.suspended = true`, which is what the editor window's `visible` binding
reads. A chooser that never exited left `suspended` true forever: the editor
gone, `Esc` not reaching it, and killing the process by hand the only way out.

Fixed: the chooser runs under `timeout` like every other subprocess here, with
a `chooserWatchdog` behind it that calls `resume()` and logs. Five minutes,
because a person choosing a file is allowed to take a while.

### 3. The canvas had no keyboard path

`WorkspaceCanvas.qml`

Panes, tabs, dividers and the split/close controls were all pointer-only, and
the application rows were not focusable either. The list-and-fields form the
canvas replaced was fully tabbable.

Fixed: the board takes Tab and draws a focus ring. Arrows walk the panes
geometrically — the pane *beside* this one, not its sibling in the split, which
on a grid are different panes. Enter goes into the box on a pane that has one
and opens the picker on a pane that does not, Delete closes the pane, and Ctrl
with an arrow splits it the way the arrow points. The tab buttons advertised
`focusable` and had nothing listening for the Return it wires up; they do now.
The application list takes Tab, walks with Up and Down, and adds with Enter,
and Down from the search field steps into it.

### 4. The application list could not be dragged to scroll

`WorkspaceCanvas.qml` — the `appDrag` MouseArea

`preventStealing: true` from the press is what let a drag start on a row
without the ListView claiming it as a flick. The cost was that the list only
scrolled with a wheel, which on a touchpad is a real loss.

Fixed: `preventStealing` is claimed rather than declared. A gesture that sets
off sideways is a drag onto the board and takes the grab; one that sets off
downwards is left alone and the ListView steals it back on its own.

### 5. Import selected the wrong mode afterwards

`EditorWindow.qml` — `confirmImport()`

`importFromText` returns `{ added, replaced, skipped }` and `confirmImport`
threw it away, then selected `modes[modes.length - 1]`. Import as *replace*
over existing ids appends nothing, so the editor landed on an unrelated mode
and claimed to have imported it.

Fixed: it selects `added[0]` or `replaced[0]`, and logs how many were skipped.

### 6. Export overwrote without asking

`EditorWindow.qml` — `exportAll()`, `writeExport()`

The folder chooser hands back a directory and the export always wrote
`omara-export.json` into it, so a second export to the same folder silently
replaced the first.

Fixed: the name carries a timestamp to the second.

### 7. A capture and an activation shared one probe result

`Service.qml` — `probeResult`

`probeProcess` and `captureProcess` both assigned `service.probeResult` and
neither excluded the other, so the snapshot an activation stored for restore
could come from a capture's read. In practice both read the same two files a
moment apart and the values matched — but nothing made that true.

Fixed: capture has its own `captureResult`, cleared when a capture starts and
when it finishes.

### 8. A renamed copy skipped normalization

`Model.js` — `importModes()`, the `copy` branch

`copy.name = ctx.name + " (copy)"` was assigned after `normalizeMode` had run,
so the suffix was appended to an already-clamped name and the result could sit
a few characters past `MAX_STRING`.

Fixed: renamed before normalizing.

### 9. Two identical windows captured as one

`Model.js` — `captureMode()`

Capture keyed windows on `desktopId + args + directory + workspace` and dropped
duplicates. Two bare terminals on one workspace produce the same key for both,
so the second was thrown away — and two bare terminals side by side are exactly
the case where the only thing telling them apart is where they are.

Fixed: one window, one pane. The dedupe is gone, and the capture reads
`at`/`size` off each toplevel and rebuilds the shape from it: a line with every
window cleanly on one side of it is a split, and where that line fell is the
ratio. A compositor that answers with no geometry still captures the grid it
always did.

### 10. An empty pane could not be closed

`WorkspaceCanvas.qml` — the pane controls

The split and close buttons were gated on the pane holding something, on the
theory that dropping an application into an empty pane undid the split. That is
backwards: split a pane, change your mind, and the empty half was permanent —
and normalization keeps it, so it was saved into the mode too. The only way out
was to fill it and then close what you had put in.

Fixed: an empty pane gets the ×, at a narrower width than an occupied one
because it only needs the one button. Splitting one is still not offered.

### 11. Ctrl+S discarded the field you were typing in

`EditorWindow.qml` — the `Ctrl+S` handler

Every text field here commits on `editingFinished`. `guard()` knows this and
takes focus back first so a field under the caret is seen; the `Ctrl+S` handler
called `saveDraft()` directly. If the only change was what you had just typed,
`dirty` was still false, so nothing was saved — and the handler accepted the
event, so the keystroke vanished too.

Fixed: `Ctrl+S` goes through `requestSave()`, which goes through `guard()`.

### 12. A pane's box could write its text into a different application

`WorkspaceCanvas.qml`, `ModeForm.qml` — the editing fields

Typing into a `TextField` breaks the binding on `text`, and the pane Repeaters
are modelled on a *count* so their delegates survive a change to the tree.
A field whose binding had been broken went on showing the text it was given for
a pane it was no longer drawing — and committed it there on the next blur.

Fixed: `EditField`. It holds `committed`, the value the model has, re-points
`text` whenever that changes, and refuses to write back a value it has not been
edited into. Escape reverts the field rather than walking up to close the panel.

### 13. Adding or removing a workspace left the numbers out of order

`EditorWindow.qml` — `addWorkspace()`, `removeWorkspace()`

A numbered tab is a position, and only `moveWorkspace` renumbered. Delete
workspace 2 of `1 2 3` and the strip read `1 3`; the next drag of any tab at
all then renumbered it to `1 2` and moved everything on 3 onto 2, which is not
what the drag was for.

Fixed: one `renumbered()` helper, on every change to the strip, landing flag
carried across by position.

### 14. A pane with something in it could be overwritten

`EditorWindow.qml` — `paneInsert()`

Dropping or clicking into the middle of an occupied pane called `paneSetAppAt`
on it. The evicted application was not lost — reconcile gave it a pane
somewhere else — but it moved somewhere you had not put it.

Fixed: an occupied pane splits, which is what a tiling window manager does with
a window opened onto another one. The middle has no side to it, so it splits
the way `paneAppend` alternates and both stay where you can see them.

### 15. Looking at a pane marked the mode unsaved

`EditorWindow.qml` — `setApplicationField()`, `setDraft()`

Neither compared before writing, so selecting a terminal pane and clicking away
rewrote `args` to the identical string and set `dirty`. The panel then asked
whether to save changes that did not exist, which is how you teach someone to
click through that prompt.

Fixed: a write of the value already there is not an edit.

### 16. Escape in a text field closed the whole panel

`WorkspaceCanvas.qml`, `ModeForm.qml`

A `TextField` does not consume Escape, so it walked up to `keyCatcher`. The tab
rename field handled it; nothing else did.

Fixed by `EditField` — see #12 — and the app search field, where Escape clears
the query while there is one and only an empty field lets it through.

### 17. A layout too deep to keep lost its applications

`Model.js` — `normalizePaneNode()`

Past `MAX_SPLIT_DEPTH` or the pane budget it fell through to the leaf branch
and read `raw.app` off a *split* node, which is always undefined. The whole
subtree emptied. The applications survived — reconcile re-appended them — but
silently, and the arrangement went with no record.

Fixed: the subtree collapses to the first application it held rather than to
nothing.

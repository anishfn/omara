# Known bugs

Found while reworking the editor. Each one is a separate commit's worth of
work; none of them is fixed yet. Roughly ordered by how much damage it can do.

---

### 1. `deactivate` can run in the middle of an activation

`Service.qml` — `deactivateMode()`

`activateMode` refuses to start while `activating` is true. `deactivateMode`
has no such guard, and both the bar's *Disable mode* button and `omara
deactivate` reach it directly. During the environment probe (up to 10s) a
deactivation can therefore run `restorePlan` against `previousState`, clear the
snapshot, and set `activeMode` to null — and then the activation still in
flight applies its own settings and writes itself back as active. The desktop
ends up in the new mode with an empty restore snapshot, so turning it off
afterwards restores nothing.

Fix: give `deactivateMode` the same `activating` guard, or queue it behind the
in-flight activation the way `actionQueue` already queues state changes.

---

### 2. A hung file chooser leaves the editor invisible with no way back

`EditorWindow.qml` — `suspendFor()`, `chooserCommand()`

Every other subprocess in this plugin runs under `bounded()` with a watchdog
Timer behind it. The three chooser launches (`browseWallpaper`, `browseImport`,
`exportAll`) do not: they run `omarchy-file-select` unbounded and set
`root.suspended = true`, which is what the editor window's `visible` binding
reads. If the chooser never exits — a wedged portal, a missing binary that
somehow blocks — `suspended` stays true forever. The editor is gone, `Esc` does
not reach it, and the only way out is killing the process by hand.

Fix: wrap the chooser in `bounded()` and add a Timer that calls `resume()`, the
same shape as `probeWatchdog`.

---

### 3. The canvas has no keyboard path

`WorkspaceCanvas.qml`

Panes, tabs, dividers and the split/close controls are all pointer-only. The
application rows in the list are not focusable either. `Tab` from the panel
still lands on the mode name, and everything below the canvas is reachable, but
the whole of what a mode *opens* now needs a mouse. The list-and-fields form
this replaced was fully tabbable.

Fix: `activeFocusOnTab` on the panes with arrow keys to move between them,
Enter to open the picker on the focused pane, and `Del` to close it.

---

### 4. The application list cannot be dragged to scroll

`WorkspaceCanvas.qml` — the `appDrag` MouseArea

`preventStealing: true` is what lets a drag start on a row without the ListView
claiming it as a flick. The cost is that the list no longer scrolls by dragging
it; only the wheel works. On a touchpad that is a real loss.

Fix: only prevent stealing once the drag threshold is crossed, or put the drag
on a `DragHandler` with a `grabPermissions` that yields to the flick until it
has moved horizontally.

---

### 5. Import selects the wrong mode afterwards

`EditorWindow.qml` — `confirmImport()`

`importFromText` returns `{ added, replaced }` and `confirmImport` throws it
away, then selects `modes[modes.length - 1]` — whatever happens to be last in
the list. Import as *replace* over existing ids appends nothing, so the editor
lands on an unrelated mode and claims to have imported it.

Fix: select `result.added[0] || result.replaced[0]`, and say how many were
skipped.

---

### 6. Export overwrites without asking

`EditorWindow.qml` — `exportAll()`, `writeExport()`

The folder chooser hands back a directory and the export always writes
`omara-export.json` into it. A second export to the same folder silently
replaces the first, and there is no way to choose a name.

Fix: ask for a filename, or fall back to a timestamped one when the target
already exists.

---

### 7. The keyboard cursor in the bar popup reaches invisible rows

`BarWidget.qml` — `rowCount`, `activateCursor()`

`rowCount` is `modes.length + 3` unconditionally, but *New mode*, *Manage
modes* and *Disable mode* are all `visible: modes.length > 0`. With no modes
configured the popup shows one button and the cursor still has three stops: two
of them highlight nothing and fire an action anyway.

Fix: derive `rowCount` from what is actually on screen.

---

### 8. A capture and an activation share one probe result

`Service.qml` — `probeResult`

`probeProcess` and `captureProcess` both assign `service.probeResult`, and
neither excludes the other. `captureCurrentSetup` only refuses a second
*capture*, and `startProbe` only supersedes a previous *probe*. Run a capture
while an activation is probing and whichever finishes second wins, so the
snapshot an activation stores for restore can come from the capture's read.
In practice both read the same two files a moment apart, so the values match —
but nothing makes that true.

Fix: give capture its own result property, or make the two share the
supersession that already exists within each.

---

### 9. `pane` has an undocumented value

`EditorWindow.qml` — `property string pane`

The comment says `edit | create | settings | log`. `stageImport` also sets
`"import"`, which is a real pane with real UI. Small, but the comment is the
only place the state machine is written down.

Fix: add it to the comment.

---

### 10. A renamed copy skips normalization

`Model.js` — `importModes()`, the `copy` branch

`copy.name = ctx.name + " (copy)"` is assigned after `normalizeMode` has run,
so the suffix is appended to an already-clamped name and the result can sit a
few characters past `MAX_STRING`. Harmless today because every path into it
feeds a normalized name in, but it is the one field in the file that leaves
normalization behind it.

Fix: rename before normalizing, or clamp after.

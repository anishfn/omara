import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The manage / edit overlay. One window, owned by the service.
Item {
  id: root

  property var service: null

  property bool opened: false
  property string selectedId: ""
  property var draft: null
  property bool dirty: false
  property string pane: "edit"   // edit | options | settings | log | import

  // A layer-shell overlay sits above every toplevel and holds keyboard focus,
  // so an external file chooser opens behind it. Stand down while one is up.
  property bool suspended: false

  property bool appPickerOpen: false
  property bool iconPickerOpen: false
  property bool themePickerOpen: false

  property string importPath: ""
  property string importText: ""
  property var importIncoming: []
  property bool importWarning: false
  property int importDisarmed: 0

  readonly property var modes: service ? service.modes : []
  readonly property color foreground: Color.popups.text
  readonly property color background: Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: Style.font.family

  readonly property var sinkNodes: service ? service.sinkNodes : []

  PwObjectTracker { objects: root.opened ? root.sinkNodes : [] }

  readonly property var audioOptions: {
    var out = [{ value: "", label: "Leave unchanged" }]
    for (var i = 0; i < sinkNodes.length; i++) {
      var n = sinkNodes[i]
      if (!n || !n.name) continue
      out.push({ value: String(n.name), label: String(n.description || n.nickname || n.name) })
    }
    if (draft && draft.audio && draft.audio.output) {
      var wanted = String(draft.audio.output)
      var known = false
      for (var k = 0; k < out.length; k++) if (out[k].value === wanted) known = true
      if (!known) out.push({ value: wanted, label: wanted + "  (not connected)" })
    }
    return out
  }

  readonly property var dndOptions: [
    { value: "unchanged", label: "Leave unchanged" },
    { value: "on", label: "Do Not Disturb on" },
    { value: "off", label: "Do Not Disturb off" }
  ]

  // ------------------------------------------------------------- lifecycle

  // "new" lands on a new mode, not on a screen asking which kind of new mode
  // it should be. There is only one kind.
  function openFor(modeId) {
    var id = String(modeId || "")
    root.opened = true
    if (id === "new") {
      createFromTemplate("blank")
    } else if (id !== "") {
      selectMode(id)
    } else if (modes.length > 0) {
      selectMode(modes[0].id)
    } else {
      root.pane = "edit"
      root.draft = null
      root.selectedId = ""
    }
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.appPickerOpen = false
    root.iconPickerOpen = false
    root.themePickerOpen = false
    root.draft = null
    root.dirty = false
    root.pane = "edit"
    root.importIncoming = []
    root.importText = ""
  }

  property var pendingAction: null
  property bool creating: false

  // Every route out of a half-finished edit goes through here, so unsaved work
  // can only be lost on purpose.
  function guard(action) {
    // Text fields commit on blur, so a field still under the caret has changes
    // the draft has not seen yet. Take focus back first, which fires their
    // editingFinished, then decide.
    keyCatcher.forceActiveFocus()
    Qt.callLater(function() { root.guardResolved(action) })
  }

  function guardResolved(action) {
    if (!root.dirty || !root.draft) { action(); return }
    root.pendingAction = action
    unsaved.open("Save your changes to \"" + root.draft.name + "\"?",
      ["Save", "Discard", "Cancel"], 1)
  }

  function resolveGuard(index) {
    var action = root.pendingAction
    root.pendingAction = null
    unsaved.close()
    if (index === 0) saveDraft()
    else if (index !== 1) return
    if (action) action()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function cancelGuard() {
    root.pendingAction = null
    unsaved.close()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function requestClose() { guard(function() { root.close() }) }
  function requestSelect(id) { guard(function() { root.selectMode(id) }) }
  function requestPane(next) { guard(function() { root.pane = next }) }

  function requestCreateMode() {
    guard(function() { root.createFromTemplate("blank") })
  }

  function selectMode(id) {
    var ctx = Model.findMode(service ? service.config : null, id)
    if (!ctx) return
    root.selectedId = ctx.id
    root.draft = Model.clone(ctx)
    root.dirty = false
    root.pane = "edit"
  }

  function edited() { root.dirty = true }

  function openIconPicker() {
    root.iconPickerOpen = true
    iconPicker.reset()
  }

  function setIcon(glyph) {
    root.iconPickerOpen = false
    setDraft("icon", String(glyph || ""))
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function openThemePicker() {
    root.themePickerOpen = true
    themePicker.reset(root.draft && root.draft.appearance ? root.draft.appearance.theme : "")
  }

  function setTheme(slug) {
    root.themePickerOpen = false
    setDraft("appearance.theme", String(slug || ""))
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function captureDesktop() {
    if (!service || root.creating) return
    guard(function() {
      root.creating = true
      root.pane = "edit"
      service.captureCurrentSetup("")
      Qt.callLater(function() { root.creating = false })
    })
  }

  // Which pane a picked application should land in. Set before the picker
  // opens and read when it answers, so an application chosen from a pane goes
  // into that pane instead of onto the end of a list.
  property int pendingLayout: -1
  property string pendingPath: ""

  function openAppPicker(layoutIndex, path) {
    root.pendingLayout = layoutIndex === undefined ? -1 : layoutIndex
    root.pendingPath = path === undefined ? "" : String(path)
    root.appPickerOpen = true
    appPicker.reset()
  }

  function addDesktopApplication(desktopId) {
    root.appPickerOpen = false
    if (!desktopId) return
    root.placeApplication(root.pendingLayout, root.pendingPath, "center",
      { desktopId: String(desktopId), command: "", enabled: true })
  }

  function addCustomApplication() {
    root.appPickerOpen = false
    // A blank command is not an application yet, so it cannot go through
    // normalizeApplication. It gets a pane and a uid, and the field to fill in.
    root.placeApplication(root.pendingLayout, root.pendingPath, "center",
      { desktopId: "", command: "", enabled: true })
  }

  // ------------------------------------------------------------ pane layout
  //
  // Every edit here rebuilds the whole draft through Model.reconcileMode, so
  // the panes, the application list, and each application's workspace are
  // never read while one of them is half-updated.

  readonly property var layouts: draft && draft.workspaces && Array.isArray(draft.workspaces.layouts)
    ? draft.workspaces.layouts : []

  function commitDraft(next) {
    root.draft = Model.reconcileMode(next)
    edited()
  }

  function layoutTree(index) {
    var list = root.layouts
    return (index >= 0 && index < list.length) ? list[index].tree : Model.paneLeaf("")
  }

  function setLayoutTree(index, tree) {
    if (!draft || index < 0 || index >= root.layouts.length) return
    var next = Model.clone(draft)
    next.workspaces.layouts[index].tree = tree
    commitDraft(next)
  }

  function applicationByUid(uid) {
    var key = String(uid || "")
    if (key === "" || !draft) return null
    var apps = draft.applications
    for (var i = 0; i < apps.length; i++) if (apps[i].uid === key) return apps[i]
    return null
  }

  function applicationIndexByUid(uid) {
    var key = String(uid || "")
    if (key === "" || !draft) return -1
    for (var i = 0; i < draft.applications.length; i++)
      if (draft.applications[i].uid === key) return i
    return -1
  }

  function setApplicationField(uid, field, value) {
    var index = applicationIndexByUid(uid)
    if (index === -1) return
    var next = Model.clone(draft)
    next.applications[index][field] = value
    commitDraft(next)
  }

  // A workspace only exists here as a tab; it is created empty and named
  // afterwards, the same way you would open one on the desktop.
  function addWorkspace() {
    if (!draft || root.layouts.length >= Model.MAX_LAYOUTS) return -1
    var taken = {}
    for (var i = 0; i < root.layouts.length; i++) taken["w:" + root.layouts[i].workspace] = true
    var n = 1
    while (taken["w:" + n] && n < 100) n++
    var next = Model.clone(draft)
    next.workspaces.layouts.push({ workspace: String(n), tree: Model.paneLeaf("") })
    commitDraft(next)
    return next.workspaces.layouts.length - 1
  }

  // Dragging a tab moves what is inside it, not the number on it. A numbered
  // tab is a position: the strip still reads 1, 2, 3 across afterwards, and
  // the applications that were on the second workspace are now on the first.
  // Moving the number instead would leave you looking at a strip that reads
  // 2, 1, 3 and wondering which of those is the one things open on.
  //
  // A tab the user named is a label rather than a position, so it travels
  // with its contents and keeps its name. Model.renumberLayouts knows the
  // difference; this only has to put the landing flag back afterwards,
  // because the workspace it pointed at has very likely been renumbered.
  function moveWorkspace(from, to) {
    if (!draft) return
    var count = root.layouts.length
    if (from < 0 || from >= count || to < 0 || to >= count || from === to) return

    var next = Model.clone(draft)
    var moved = next.workspaces.layouts.splice(from, 1)[0]
    next.workspaces.layouts.splice(to, 0, moved)

    var landing = -1
    var target = next.workspaces.target
    if (target !== null && target !== undefined) {
      for (var i = 0; i < next.workspaces.layouts.length; i++) {
        if (String(next.workspaces.layouts[i].workspace) === String(target)) { landing = i; break }
      }
    }

    next.workspaces.layouts = Model.renumberLayouts(next.workspaces.layouts)
    if (landing >= 0)
      next.workspaces.target = Model.asWorkspace(next.workspaces.layouts[landing].workspace)

    commitDraft(next)
  }

  // The applications in a removed workspace go with it. Leaving them behind
  // would only put the tab back, since an application with a workspace and no
  // pane is given one on the next reconcile.
  function removeWorkspace(index) {
    if (!draft || index < 0 || index >= root.layouts.length) return
    if (root.layouts.length <= 1) return
    var doomed = {}
    var uids = Model.paneApps(root.layouts[index].tree, [])
    for (var u = 0; u < uids.length; u++) doomed["u:" + uids[u]] = true
    var next = Model.clone(draft)
    next.workspaces.layouts.splice(index, 1)
    var kept = []
    for (var a = 0; a < next.applications.length; a++)
      if (!doomed["u:" + next.applications[a].uid]) kept.push(next.applications[a])
    next.applications = kept
    if (next.workspaces.target !== null && String(next.workspaces.target) === String(root.layouts[index].workspace))
      next.workspaces.target = null
    commitDraft(next)
  }

  // Two tabs cannot name one workspace: the second would silently swallow the
  // first on the next reconcile.
  function renameWorkspace(index, value) {
    if (!draft || index < 0 || index >= root.layouts.length) return false
    var raw = String(value || "").trim()
    var ref = raw === "" ? "" : Model.workspaceRef(raw)
    if (raw !== "" && ref === "") return false
    for (var i = 0; i < root.layouts.length; i++)
      if (i !== index && root.layouts[i].workspace === ref) return false
    if (root.layouts[index].workspace === ref) return true
    var was = root.layouts[index].workspace
    var next = Model.clone(draft)
    next.workspaces.layouts[index].workspace = ref
    if (next.workspaces.target !== null && String(next.workspaces.target) === String(was))
      next.workspaces.target = ref === "" ? null : ref
    commitDraft(next)
    return true
  }

  function setLandingWorkspace(value) {
    setDraft("workspaces.target", value)
  }

  // Drops a new application into a pane. An occupied pane splits in the
  // direction the pointer came in from, which is the same gesture a tiling
  // window manager answers to.
  function placeApplication(layoutIndex, path, zone, fields) {
    if (!draft) return
    var index = layoutIndex >= 0 && layoutIndex < root.layouts.length ? layoutIndex : 0
    if (root.layouts.length === 0) return
    var app = {
      uid: "",
      desktopId: String(fields.desktopId || ""),
      command: String(fields.command || ""),
      args: String(fields.args || ""),
      directory: String(fields.directory || ""),
      workspace: null,
      note: "",
      enabled: fields.enabled !== false
    }
    var next = Model.clone(draft)
    app.uid = Model.freshApplicationUid(next.applications)
    var was = next.workspaces.layouts[index].tree
    var tree = root.paneInsert(was, path, zone, app.uid)
    // The pane budget is spent and there is nowhere to put this. Refusing the
    // drop is the honest answer; adding the application anyway would leave it
    // launching from a mode that has no pane to show it in.
    if (tree === was) {
      if (service) service.log("warn", "This workspace is full; close a pane first")
      return
    }
    next.applications.push(app)
    next.workspaces.layouts[index].tree = tree
    commitDraft(next)
  }

  // Shared by a drop from the picker and a drop from another pane.
  function paneInsert(tree, path, zone, uid) {
    var target = Model.paneAt(tree, path)
    if (!target || Model.isPaneSplit(target)) {
      var empty = Model.paneFirstEmpty(tree, "")
      return empty === null ? Model.paneAppend(tree, uid) : Model.paneSetAppAt(tree, empty, uid)
    }
    if (target.app === "" || zone === "center") return Model.paneSetAppAt(tree, path, uid)

    var direction = (zone === "top" || zone === "bottom") ? "column" : "row"
    var split = Model.paneSplitAt(tree, path, direction)
    // The pane budget is spent. Take an empty pane if there is one and
    // otherwise hand the tree back untouched, so a full workspace refuses a
    // drop rather than throwing out what was already in that pane.
    if (split === tree) {
      var spare = Model.paneFirstEmpty(tree, "")
      return spare === null ? tree : Model.paneSetAppAt(tree, spare, uid)
    }
    if (zone === "left" || zone === "top") {
      split = Model.paneSetAppAt(split, path + "0", uid)
      return Model.paneSetAppAt(split, path + "1", target.app)
    }
    return Model.paneSetAppAt(split, path + "1", uid)
  }

  function movePaneApp(fromIndex, fromPath, toIndex, toPath, zone) {
    if (!draft) return
    if (fromIndex < 0 || fromIndex >= root.layouts.length) return
    if (toIndex < 0 || toIndex >= root.layouts.length) return
    var source = Model.paneAt(root.layouts[fromIndex].tree, fromPath)
    if (!source || Model.isPaneSplit(source) || source.app === "") return
    if (fromIndex === toIndex && fromPath === toPath) return
    var uid = source.app
    var next = Model.clone(draft)

    if (fromIndex === toIndex) {
      var tree = next.workspaces.layouts[toIndex].tree
      var target = Model.paneAt(tree, toPath)
      if (target && !Model.isPaneSplit(target) && target.app !== "" && zone === "center") {
        // Two occupied panes trade places rather than one overwriting the other.
        tree = Model.paneSetAppAt(tree, toPath, uid)
        tree = Model.paneSetAppAt(tree, fromPath, target.app)
      } else {
        // Emptying the source first keeps toPath pointing where it did.
        var emptied = Model.paneSetAppAt(tree, fromPath, "")
        tree = root.paneInsert(emptied, toPath, zone, uid)
        // Nowhere to land: leave the application where it was rather than
        // emptying its pane and dropping it on the floor.
        if (tree === emptied) return
      }
      next.workspaces.layouts[toIndex].tree = tree
    } else {
      // Landed first, removed second: a target that could not take it leaves
      // both workspaces exactly as they were.
      var landed = root.paneInsert(next.workspaces.layouts[toIndex].tree, toPath, zone, uid)
      if (landed === next.workspaces.layouts[toIndex].tree) return
      next.workspaces.layouts[fromIndex].tree =
        Model.paneRemoveAt(next.workspaces.layouts[fromIndex].tree, fromPath)
      next.workspaces.layouts[toIndex].tree = landed
    }
    commitDraft(next)
  }

  function splitPane(index, path, direction) {
    setLayoutTree(index, Model.paneSplitAt(root.layoutTree(index), path, direction))
  }

  // Closing a pane closes what is in it. An empty pane just goes away.
  function closePane(index, path) {
    if (!draft || index < 0 || index >= root.layouts.length) return
    var node = Model.paneAt(root.layouts[index].tree, path)
    if (!node || Model.isPaneSplit(node)) return
    var next = Model.clone(draft)
    if (node.app !== "") {
      var kept = []
      for (var a = 0; a < next.applications.length; a++)
        if (next.applications[a].uid !== node.app) kept.push(next.applications[a])
      next.applications = kept
    }
    next.workspaces.layouts[index].tree = Model.paneRemoveAt(next.workspaces.layouts[index].tree, path)
    commitDraft(next)
  }

  function setPaneRatio(index, path, ratio) {
    if (!draft || index < 0 || index >= root.layouts.length) return
    // Straight onto the draft: a resize fires on every mouse move, and going
    // through reconcile each time would rebuild the application list per pixel.
    var next = Model.clone(draft)
    next.workspaces.layouts[index].tree =
      Model.paneSetRatioAt(next.workspaces.layouts[index].tree, path, ratio)
    root.draft = next
    edited()
  }

  function applicationName(app) {
    if (!app) return ""
    if (!app.desktopId) return String(app.command || "")
    var entry = service ? service.desktopEntry(app.desktopId) : null
    if (entry) return String(entry.name || app.desktopId)
    return String(app.desktopId) + "  (not installed)"
  }

  // A .desktop file says so itself. Guessing from the name would call
  // "Terminal Emoji Picker" a terminal and miss anything not called one.
  function applicationIsTerminal(app) {
    if (!app || !app.desktopId || !service) return false
    var entry = service.desktopEntry(app.desktopId)
    return entry ? Model.isTerminalCategories(entry.categories) : false
  }

  function applicationIcon(app) {
    if (!app || !app.desktopId || !service || !service.appLibrary) return ""
    var entry = service.desktopEntry(app.desktopId)
    return service.appLibrary.iconSource(entry ? String(entry.icon || "") : "")
  }

  function saveDraft() {
    if (!service || !draft) return
    service.updateModeFields(draft.id, draft)
    root.dirty = false
    selectMode(draft.id)
  }

  function revertDraft() {
    if (selectedId) selectMode(selectedId)
  }

  // Trying a mode means being in it. The editor is a layer-shell overlay that
  // covers every toplevel, so anything this launches would open behind it.
  function testDraft() {
    if (!service || !draft) return
    var id = draft.id
    if (root.dirty) saveDraft()
    root.close()
    service.activateMode(id)
  }

  // What this mode adds up to, in the one line the footer has for it.
  readonly property string draftSummary: {
    if (!draft) return ""
    var apps = draft.applications.length
    if (apps === 0) return "nothing set up yet"
    var used = 0
    var list = root.layouts
    for (var i = 0; i < list.length; i++)
      if (Model.paneApps(list[i].tree, []).length > 0) used++
    var out = apps + (apps === 1 ? " app on " : " apps on ") + used
      + (used === 1 ? " workspace" : " workspaces")
    if (draft.workspaces.target !== null && draft.workspaces.target !== undefined)
      out += ", lands on " + draft.workspaces.target
    return out
  }

  function createFromTemplate(key) {
    if (!service || root.creating) return
    root.creating = true
    var id = service.createFromTemplate(key)
    if (id) selectMode(id)
    Qt.callLater(function() { root.creating = false })
  }

  function moveDraftListItem(path, index, delta) {
    setDraft(path, Model.moveInList(draftList(path), index, delta))
  }

  function duplicateSelected() {
    if (!service || !selectedId) return
    guard(function() {
      var id = service.duplicateMode(root.selectedId)
      if (id) root.selectMode(id)
    })
  }

  function moveSelected(delta) {
    if (!service || !selectedId) return
    service.reorderMode(selectedId, delta)
  }

  function deleteSelected() {
    if (!service || !selectedId) return
    var next = ""
    for (var i = 0; i < modes.length; i++) if (modes[i].id !== selectedId) { next = modes[i].id; break }
    service.removeMode(selectedId)
    root.draft = null
    root.selectedId = ""
    if (next) selectMode(next)
    else root.pane = "edit"
  }

  // Replaces the whole draft; mutating a nested field would not re-evaluate
  // the bindings reading it.
  function setDraft(path, value) {
    if (!draft) return
    var next = Model.clone(draft)
    var parts = String(path).split(".")
    var cursor = next
    for (var i = 0; i < parts.length - 1; i++) {
      if (!Model.isPlainObject(cursor[parts[i]])) cursor[parts[i]] = {}
      cursor = cursor[parts[i]]
    }
    cursor[parts[parts.length - 1]] = value
    root.draft = next
    edited()
  }

  function pushDraftList(path, value) {
    var list = draftList(path).slice()
    list.push(value)
    setDraft(path, list)
  }

  function removeDraftListItem(path, index) {
    var list = draftList(path).slice()
    list.splice(index, 1)
    setDraft(path, list)
  }

  function setDraftListItem(path, index, value) {
    var list = draftList(path).slice()
    list[index] = value
    setDraft(path, list)
  }

  function draftList(path) {
    if (!draft) return []
    var parts = String(path).split(".")
    var cursor = draft
    for (var i = 0; i < parts.length; i++) {
      if (!cursor) return []
      cursor = cursor[parts[i]]
    }
    return Array.isArray(cursor) ? cursor : []
  }

  // ------------------------------------------------------- import / export

  // Through the same guarded writer as everything else: a fresh 0600 temp in a
  // verified directory, renamed over the target, and an answer either way.
  // Handing the whole export to a detached shell put it on a command line and
  // logged success before anything had been written.
  function writeExport(target, payload) {
    if (!root.service) return
    root.service.writeGuarded(String(target), String(payload), function(verdict, detail) {
      if (verdict === "ok") root.service.log("info", "Exported modes to " + target)
      else root.service.log("warn", "Could not write " + target + ": " + detail)
    })
  }

  function chooserCommand(argv) {
    return ["bash", "-lc", 'exec "$@"', "bash"].concat(argv)
  }

  function suspendFor(process, argv) {
    process.command = chooserCommand(argv)
    root.suspended = true
    process.running = true
  }

  function resume() {
    root.suspended = false
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function firstLine(text) {
    return String(text || "").trim().split("\n")[0]
  }

  function browseWallpaper() {
    suspendFor(wallpaperPicker, ["omarchy-file-select", "--title", "Pick a wallpaper", "--extensions", "png jpg jpeg webp"])
  }

  property string chooserError: ""

  // Resume first, unconditionally: no reporting bug may strand the user with a
  // dismissed chooser and no editor.
  function chooserFinished(exitCode) {
    root.resume()
    if (exitCode === 0 || exitCode === 1) { root.chooserError = ""; return }
    var detail = root.chooserError.trim().split("\n").pop()
    root.chooserError = ""
    if (service) service.log("warn", "The file chooser exited " + exitCode + (detail ? ": " + detail : ""))
  }

  Process {
    id: wallpaperPicker
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = root.firstLine(text)
        if (path !== "" && root.draft) root.setDraft("appearance.wallpaper", path)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.chooserError = String(text || "")
    }
    onExited: function(exitCode) { root.chooserFinished(exitCode) }
  }

  function browseImport() {
    suspendFor(importPicker, ["omarchy-file-select", "--title", "Import modes", "--extensions", "json"])
  }

  Process {
    id: importPicker
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = root.firstLine(text)
        if (path === "" || !root.service) return
        root.importPath = path
        // The chooser hands back a pathname the user picked, which is no more
        // trustworthy than any other pathname. It goes through the same
        // no-follow, non-blocking, byte-capped read as the config.
        root.service.readGuarded(path, function(verdict, detail, content) {
          if (verdict === "ok") { root.stageImport(content); return }
          root.importIncoming = []
          root.service.log("warn", verdict === "absent"
            ? "Import failed: " + path + " is not there any more"
            : "Import failed: " + detail)
        })
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.chooserError = String(text || "")
    }
    onExited: function(exitCode) { root.chooserFinished(exitCode) }
  }


  function stageImport(text) {
    var parsed = Model.parseImport(text)
    if (parsed.error) {
      if (service) service.log("warn", "Import failed: " + parsed.error)
      root.importIncoming = []
      return
    }
    var preview = Model.importPreview(parsed.modes)
    var warn = false
    for (var i = 0; i < preview.length; i++)
      if (preview[i].runs.length > 0) warn = true
    root.importIncoming = preview
    root.importWarning = warn
    root.importDisarmed = parsed.disarmed
    root.importText = text
    root.pane = "import"
  }

  function confirmImport(how) {
    if (!service) return
    service.importFromText(root.importText, how)
    root.importIncoming = []
    root.importText = ""
    root.pane = "edit"
    if (modes.length > 0) selectMode(modes[modes.length - 1].id)
  }

  function exportAll() {
    suspendFor(exportPicker, ["omarchy-file-select", "--title", "Export modes to a folder", "--directory"])
  }

  Process {
    id: exportPicker
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.chooserError = String(text || "")
    }
    onExited: function(exitCode) { root.chooserFinished(exitCode) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dir = root.firstLine(text)
        if (dir === "" || !root.service) return
        root.writeExport(dir + "/wsmodes-export.json", root.service.exportText(null))
      }
    }
  }

  // ------------------------------------------------------------------ window

  PanelWindow {
    id: editorWindow
    visible: root.opened && !root.suspended
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "wsmodes-editor"
    WlrLayershell.layer: WlrLayer.Overlay

    // Exclusive for long enough to take the keyboard, then OnDemand.
    //
    // Held exclusively, this surface receives every key on the system for as
    // long as it is open: a panel left up while you work in a terminal is
    // delivered your typing, and Enter or Space on a focused button is enough
    // to create, capture or delete a mode you never touched. OnDemand hands
    // the keyboard back the moment another window is focused, and the prime
    // is what still gets focus at map time so Escape and Ctrl+S work the
    // instant it opens, without a click. Same shape the shell's own
    // KeyboardPanel uses.
    property bool focusPrimed: false
    WlrLayershell.keyboardFocus: visible
      ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    onVisibleChanged: {
      editorWindow.focusPrimed = false
      if (visible) focusPrime.restart()
      else focusPrime.stop()
    }

    Timer {
      id: focusPrime
      // Long enough for the commit cycles that map the surface, short enough
      // that the exclusive window is not something you could type into.
      interval: 75
      onTriggered: if (editorWindow.visible) editorWindow.focusPrimed = true
    }

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.72)
      MouseArea {
        anchors.fill: parent
        onClicked: if (!root.appPickerOpen && !root.iconPickerOpen && !root.themePickerOpen && !unsaved.opened) root.requestClose()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: {
        if (root.appPickerOpen) root.appPickerOpen = false
        else if (root.iconPickerOpen) root.iconPickerOpen = false
        else if (root.themePickerOpen) root.themePickerOpen = false
        else if (unsaved.opened) root.cancelGuard()
        else root.requestClose()
      }

      // Only reached while nothing inside has focus, which makes it the entry
      // point into the form rather than a step in the middle of it.
      Keys.onTabPressed: function(event) {
        if (root.pane === "options" && modeForm.visible) {
          modeForm.focusFirstField()
          event.accepted = true
        }
      }

      // Ctrl+S and Ctrl+N reach here from whichever field has focus, because
      // key events walk up the parent chain unhandled.
      Keys.onPressed: function(event) {
        // Alt+Up/Down reorders the selected mode, the keyboard equivalent of
        // the arrows that appear on a hovered row.
        if ((event.modifiers & Qt.AltModifier) && root.selectedId !== "") {
          if (event.key === Qt.Key_Up) { root.moveSelected(-1); event.accepted = true; return }
          if (event.key === Qt.Key_Down) { root.moveSelected(1); event.accepted = true; return }
        }
        if (!(event.modifiers & Qt.ControlModifier)) return
        if (event.key === Qt.Key_S) {
          if (root.pane === "edit" && root.dirty) root.saveDraft()
          event.accepted = true
        } else if (event.key === Qt.Key_N) {
          root.requestCreateMode()
          event.accepted = true
        } else if (event.key === Qt.Key_D && root.draft) {
          root.duplicateSelected()
          event.accepted = true
        }
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        // One size, not one per pane. The canvas is the content now, and a
        // card that resized itself around whichever sheet was open made every
        // trip through Options a jump cut.
        width: Math.min(parent.width - Style.space(64), Style.space(1020))
        height: Math.min(parent.height - Style.space(64), Style.space(660))
        radius: Style.cornerRadius
        // The popup surface colour carries alpha. That reads well on a menu
        // with six rows in it; on a board of panes the desktop behind shows
        // through every one of them and you cannot tell a pane from a window.
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: Color.popups.border

        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.space(10)

          // ------------------------------------------------------ header
          //
          // The modes are chips rather than a column down the side: a mode is
          // a thing you switch between, not a document you browse, and the
          // room the old sidebar took is room the canvas needed.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(4)

            Flickable {
              // Sized to the chips, so New and Capture sit next to the last
              // mode rather than across the card from it. It only becomes a
              // scroller once there are more modes than the row can hold.
              //
              // Whole pixels, with one to spare on every side. Clipping is a
              // scissor rectangle: a chip sized to the content exactly puts
              // its border on the boundary, and the boundary is where a real
              // gets rounded away — which took the edge off the last chip.
              Layout.fillWidth: true
              Layout.maximumWidth: Math.ceil(chips.implicitWidth) + 2
              Layout.preferredHeight: Math.ceil(newMode.implicitHeight) + 2
              contentWidth: Math.ceil(chips.implicitWidth) + 2
              contentHeight: height
              clip: true
              flickableDirection: Flickable.HorizontalFlick
              boundsBehavior: Flickable.StopAtBounds

              Row {
                id: chips
                x: 1
                y: 1
                spacing: Style.space(4)

                Repeater {
                  model: root.modes

                  Button {
                    required property var modelData

                    text: modelData.name
                    // A mode with no icon still shows the slot, so the way to
                    // give it one is on the chip rather than only behind
                    // Options — and so selecting a chip does not change its
                    // width by suddenly finding room for an icon.
                    iconText: modelData.icon ? String(modelData.icon) : Model.Glyph.iconSlot
                    bordered: true
                    focusable: true
                    selected: root.selectedId === modelData.id
                    active: root.service && root.service.activeModeId === modelData.id
                    foreground: modelData.enabled === false ? root.dim : root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    // A mode with no icon is a shorter row of content than a
                    // mode with one, and a row of chips that changes height
                    // per mode reads as a row of chips that are cut off.
                    height: newMode.implicitHeight
                    tooltipText: root.selectedId === modelData.id
                      ? "Click again to rename it or change its icon"
                      : (modelData.description || "")
                    Accessible.name: "Edit the mode " + modelData.name
                    // Selecting a different mode is a route out of a
                    // half-finished edit and goes through the guard. Clicking
                    // the one already open is not going anywhere, so it does
                    // the next most useful thing instead.
                    onClicked: {
                      if (root.selectedId === modelData.id) root.openIconPicker()
                      else root.requestSelect(modelData.id)
                    }
                  }
                }
              }
            }

            Button {
              id: newMode
              iconText: Model.Glyph.add
              tooltipText: "New mode  ·  Ctrl+N"
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              Accessible.name: "New mode"
              bordered: true
              onClicked: root.requestCreateMode()
            }

            Button {
              iconText: Model.Glyph.capture
              tooltipText: "Make a mode out of the desktop as it is now"
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              Accessible.name: "Capture the desktop"
              bordered: true
              onClicked: root.captureDesktop()
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

            Button {
              text: "Options"
              visible: root.draft !== null
              selected: root.pane === "options"
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: "Name, environment, commands, triggers"
              onClicked: root.pane = root.pane === "options" ? "edit" : "options"
            }

            Button {
              text: "Test"
              visible: root.draft !== null
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: "Save, close, and switch to this mode now"
              Accessible.name: "Try this mode now"
              onClicked: root.testDraft()
            }

            Button {
              text: "Save"
              visible: root.draft !== null
              bordered: true
              focusable: true
              tooltipText: "Ctrl+S"
              enabled: root.dirty
              foreground: root.dirty ? root.foreground : root.dim
              fontFamily: root.fontFamily
              onClicked: root.saveDraft()
            }

            PanelActionButton {
              iconText: Model.Glyph.close
              tooltipText: "Close"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              onClicked: root.requestClose()
            }
          }

          // ------------------------------------------------------- body
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ------------------------------------------------- canvas
            WorkspaceCanvas {
              id: canvas
              anchors.fill: parent
              visible: root.pane === "edit" && root.draft !== null
              editor: root
            }

            // -------------------------------------------- empty state
            Column {
              anchors.centerIn: parent
              width: Math.min(parent.width, Style.space(360))
              spacing: Style.space(10)
              visible: root.pane === "edit" && root.draft === null

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Nothing here yet.\nA mode is a way your desktop is set up."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(6)

                Button {
                  iconText: Model.Glyph.capture
                  text: "Capture the desktop"
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.captureDesktop()
                }

                Button {
                  iconText: Model.Glyph.add
                  text: "Start empty"
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.requestCreateMode()
                }
              }
            }

            // ------------------------------------------------- sheets
            //
            // Everything that is not the canvas lives behind one of these, on
            // the same card rather than in a window of its own, so nothing can
            // stack above the overlay and nothing has to be dismissed twice.
            Flickable {
              id: sheetFlick
              anchors.fill: parent
              visible: root.pane !== "edit"
              clip: true
              contentWidth: width
              contentHeight: sheet.implicitHeight
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: sheet
                width: sheetFlick.width
                spacing: Style.space(12)

                // ------------------------------------------- options
                Column {
                  width: parent.width
                  spacing: Style.space(12)
                  visible: root.pane === "options" && root.draft !== null

                  ModeForm {
                    id: modeForm
                    width: parent.width
                    editor: root
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }

                  Row {
                    spacing: Style.space(6)

                    Button {
                      iconText: Model.Glyph.duplicate
                      text: "Duplicate"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      focusable: true
                      tooltipText: "Ctrl+D"
                      onClicked: root.duplicateSelected()
                    }

                    Button {
                      iconText: Model.Glyph.remove
                      text: "Delete"
                      foreground: Color.urgent
                      fontFamily: root.fontFamily
                      focusable: true
                      onClicked: deleteConfirm.opened = true
                    }
                  }
                }

                // ---------------------------------------------- import
                Column {
                  width: parent.width
                  spacing: Style.space(8)
                  visible: root.pane === "import"

                  PanelSectionHeader { width: parent.width; text: "Import"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: root.importIncoming.length + " mode(s) in " + root.importPath
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Rectangle {
                    width: parent.width
                    visible: root.importWarning
                    height: warnText.implicitHeight + Style.space(16)
                    radius: Style.cornerRadius
                    color: Util.alpha(Color.urgent, 0.12)
                    border.width: 1
                    border.color: Util.alpha(Color.urgent, 0.5)

                    Text {
                      id: warnText
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      wrapMode: Text.Wrap
                      textFormat: Text.PlainText
                      text: "⚠  Activating one of these modes runs the lines below as you, `sh` ones through bash. Read them before you import."
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Repeater {
                    model: root.importIncoming

                    Column {
                      required property var modelData
                      width: sheet.width
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: "• " + modelData.name
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      // The lines themselves, not a count of them. Consent to
                      // "3 modes, some of which run things" is not consent.
                      Repeater {
                        model: modelData.runs

                        Text {
                          required property string modelData
                          width: sheet.width - Style.space(16)
                          x: Style.space(16)
                          wrapMode: Text.Wrap
                          textFormat: Text.PlainText
                          text: modelData
                          color: Color.urgent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: root.importDisarmed > 0
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: root.importDisarmed + " automatic trigger(s) in this file will be imported as "
                      + "\"ask\" instead. An imported mode never activates itself; turn one back to "
                      + "automatic yourself once you trust it."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "If a mode with the same id already exists, \"Create copy\" keeps both. That is the only choice that cannot lose what you already have."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Row {
                    spacing: Style.space(6)

                    Button {
                      text: "Cancel"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: { root.importIncoming = []; root.pane = "edit" }
                    }

                    Button {
                      text: "Create copy"
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.confirmImport("copy")
                    }

                    Button {
                      text: "Replace existing"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.confirmImport("replace")
                    }
                  }
                }

                // -------------------------------------------- activity
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.pane === "log"

                  PanelSectionHeader { width: parent.width; text: "Activity"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Text {
                    width: parent.width
                    visible: !root.service || root.service.activityLog.length === 0
                    text: "Nothing yet. Activating a mode logs what it changed here."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                  }

                  Repeater {
                    model: root.service ? root.service.activityLog : []

                    Column {
                      required property var modelData
                      required property int index

                      // The log is newest first, so a run starts at its
                      // "Activating" line and the rule goes below it.
                      readonly property bool runStart: String(modelData.message).indexOf("Activating ") === 0

                      width: sheet.width
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: Qt.formatDateTime(new Date(modelData.at), "HH:mm") + "  "
                          + (modelData.level === "warn" ? "⚠  " : "·  ") + modelData.message
                        color: modelData.level === "warn" ? Color.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.Wrap
                      }

                      Rectangle {
                        width: parent.width
                        height: 1
                        visible: parent.runStart && index < (root.service ? root.service.activityLog.length - 1 : 0)
                        color: Util.alpha(root.foreground, 0.10)
                      }
                    }
                  }

                  Button {
                    visible: root.service && root.service.activityLog.length > 0
                    text: "Clear"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    focusable: true
                    onClicked: if (root.service) root.service.clearLog()
                  }
                }

                // -------------------------------------------- settings
                Column {
                  width: parent.width
                  spacing: Style.space(8)
                  visible: root.pane === "settings"

                  PanelSectionHeader { width: parent.width; text: "Behavior"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Repeater {
                    model: [
                      { key: "launchApps", label: "Launch applications", description: "A mode may start the apps it lists" },
                      { key: "showNotifications", label: "Show a notification", description: "One summary per switch, never one per action" },
                      { key: "confirmWindowsOnSwitch", label: "Ask about open windows", description: "Offer to close what is open before switching" },
                      { key: "triggersEnabled", label: "Automatic triggers", description: "Watch for apps that should switch mode" },
                      { key: "confirmAutomaticSwitch", label: "Ask before switching", description: "A trigger asks first unless it says otherwise" },
                      { key: "restoreOnStart", label: "Restore after shell restart", description: "Reapply settings only, never relaunches apps" }
                    ]

                    Toggle {
                      required property var modelData
                      width: sheet.width
                      label: modelData.label
                      description: modelData.description
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      checked: root.service ? root.service.config.behavior[modelData.key] === true : false
                      onClicked: if (root.service) root.service.setBehavior(modelData.key, !checked)
                    }
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }

                  Row {
                    spacing: Style.space(6)

                    Button {
                      iconText: Model.Glyph.importFile
                      text: "Import"
                      focusable: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.browseImport()
                    }

                    Button {
                      iconText: Model.Glyph.exportFile
                      text: "Export"
                      focusable: true
                      enabled: root.modes.length > 0
                      foreground: root.modes.length > 0 ? root.foreground : root.dim
                      fontFamily: root.fontFamily
                      onClicked: root.exportAll()
                    }
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: "Config: ~/.config/omarchy/wsmodes.json"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ------------------------------------------------------ footer
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            ToggleSwitch {
              visible: root.draft !== null
              checked: root.draft ? root.draft.enabled !== false : true
              foreground: root.foreground
              Accessible.name: "Show this mode in the switcher"
              onToggled: root.setDraft("enabled", !checked)
            }

            Text {
              visible: root.draft !== null
              text: "Show this mode in the switcher"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

            Text {
              visible: root.dirty
              text: "Unsaved"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.draft !== null
              textFormat: Text.PlainText
              text: root.draftSummary
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              text: "Activity"
              focusable: true
              fontSize: Style.font.caption
              selected: root.pane === "log"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: root.requestPane(root.pane === "log" ? "edit" : "log")
            }

            Button {
              text: "Settings"
              focusable: true
              fontSize: Style.font.caption
              selected: root.pane === "settings"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: root.requestPane(root.pane === "settings" ? "edit" : "settings")
            }
          }
        }

        PromptDialog {
          id: unsaved
          anchors.fill: parent
          z: 10
          foreground: root.foreground
          background: root.background
          fontFamily: root.fontFamily
          onChosen: function(index) { root.resolveGuard(index) }
          onDismissed: root.cancelGuard()
        }

        IconPicker {
          id: iconPicker
          anchors.fill: parent
          visible: root.iconPickerOpen
          editor: root
          onChosen: function(glyph) { root.setIcon(glyph) }
          onCleared: root.setIcon("")
          onDismissed: {
            root.iconPickerOpen = false
            Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
          }
        }

        ThemePicker {
          id: themePicker
          anchors.fill: parent
          visible: root.themePickerOpen
          editor: root
          onChosen: function(slug) { root.setTheme(slug) }
          onCleared: root.setTheme("")
          onDismissed: {
            root.themePickerOpen = false
            Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
          }
        }

        AppPicker {
          id: appPicker
          anchors.fill: parent
          visible: root.appPickerOpen
          editor: root
          onChosen: function(desktopId) { root.addDesktopApplication(desktopId) }
          onCustomRequested: root.addCustomApplication()
          onDismissed: {
            root.appPickerOpen = false
            Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
          }
        }

        ConfirmDialog {
          id: deleteConfirm
          anchors.fill: parent
          message: root.draft ? "Delete the mode \"" + root.draft.name + "\"?" : ""
          confirmText: "Delete"
          foreground: root.foreground
          background: root.background
          fontFamily: root.fontFamily
          onConfirmed: { deleteConfirm.opened = false; root.deleteSelected() }
          onCanceled: deleteConfirm.opened = false
        }
      }
    }
  }
}

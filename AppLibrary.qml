import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "AppSearch.js" as AppSearch

// The installed applications, as the editor's sidebar and the app picker read
// them.
//
// The shell has a library of its own and injects it as `shell.appLibrary` —
// but only into a plugin whose manifest declares the `menu` kind, which is the
// launcher's kind, not this one's. Every other plugin is handed null, so the
// sidebar and the picker came up empty with nothing in the log to say why.
// Declaring `menu` to get at it is not the fix: that kind moves a plugin onto
// the shell's panel loader and would take this plugin's bar widget with it.
//
// So the plugin reads the desktop entries itself. `DesktopEntries` is
// Quickshell's, available to anything, and the two filters the shell applies
// on top of it — the launcher's hide list and entries the .desktop file itself
// hides — are read from the same two places the shell reads them from, so the
// list here and the list in the menu hold the same applications.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})

  // Icon name -> file on disk. Qt's themed lookup misses icons installed after
  // this process started, because its cache never re-scans. Consumers call
  // refreshIcons() when they open, so an app installed a minute ago still
  // draws with its own icon.
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property bool iconIndexScanned: false

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function entrySubtext(entry) {
    return AppSearch.entrySubtext(entry)
  }

  function isHiddenEntry(entry) {
    var id = String((entry && entry.id) || "")
    return root.configuredHiddenEntryIds[id] === true
      || root.desktopHiddenEntryIds[id] === true
  }

  function sortedEntries(query) {
    var values = DesktopEntries.applications ? DesktopEntries.applications.values : []
    return AppSearch.sortedEntries(values, query, function(entry) { return root.isHiddenEntry(entry) })
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    // The app/device index first. An unconstrained themed lookup can resolve
    // an application name such as "zoom" to a zoom-in action icon instead.
    var found = root.iconIndex[value]
    if (found) return Util.fileUrl(found)
    var themed = Quickshell.iconPath(value, true)
    if (themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  // Called when a list opens. The scan is a find over the icon directories, so
  // it is never run at startup for a panel nobody has opened.
  function refreshIcons() {
    if (!iconIndexScan.running) iconIndexScan.running = true
  }

  function normalizeDesktopId(id) {
    var value = String(id || "").trim()
    if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
    return value
  }

  function idsFromLines(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    return next
  }

  function hiddenEntryScanCommand() {
    var desktop = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"),
      Quickshell.env("DESKTOP_SESSION")]
      .filter(function(v) { return String(v || "").length > 0 }).join(":")
    var script = root.omarchyPath + "/shell/services/hidden-entries.sh"
    return Util.shellQuote(script) + " " + Util.shellQuote(desktop)
  }

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.local/share/icons /usr/share/icons /usr/local/share/icons $HOME/.nix-profile/share/icons";',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [ -d "$base" ] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    // First hit wins, and the directory order above is the priority order.
    if (name.length > 0 && root.pendingIconIndex[name] === undefined)
      root.pendingIconIndex[name] = value
  }

  QtObject {
    id: hiddenEntryOutput
    property string text: ""
  }

  // Both scans run in a non-login shell on purpose. A login shell sources the
  // user's profile, and tools like mise touch ~/.local/share on activation —
  // the directory the desktop-entry watcher is watching — so every scan would
  // set off the next one.
  Process {
    id: hiddenEntryScan
    command: ["bash", "-c", root.hiddenEntryScanCommand()]
    stdout: SplitParser { onRead: function(line) { hiddenEntryOutput.text += line + "\n" } }
    onStarted: hiddenEntryOutput.text = ""
    onExited: root.desktopHiddenEntryIds = root.idsFromLines(hiddenEntryOutput.text)
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    // Swapping the property rather than mutating it re-evaluates every
    // iconSource() binding, so a newly found icon appears without the list
    // being rebuilt.
    onExited: {
      root.iconIndex = root.pendingIconIndex
      root.iconIndexScanned = true
    }
  }

  // The launcher's own hide list, so an application hidden from the menu is
  // not offered here either.
  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.configuredHiddenEntryIds = root.idsFromLines(text())
    onFileChanged: root.configuredHiddenEntryIds = root.idsFromLines(text())
    onLoadFailed: root.configuredHiddenEntryIds = ({})
  }

  // A package install touches many entries at once; one rescan covers the
  // burst.
  Timer {
    id: rescanDebounce
    interval: 400
    repeat: false
    onTriggered: {
      if (!hiddenEntryScan.running) hiddenEntryScan.running = true
      if (root.iconIndexScanned && !iconIndexScan.running) iconIndexScan.running = true
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { rescanDebounce.restart() }
  }

  Component.onCompleted: hiddenEntryScan.running = true
}

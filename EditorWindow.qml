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
  property string pane: "edit"   // edit | create | settings | log

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

  function openFor(modeId) {
    var id = String(modeId || "")
    if (id === "new") {
      root.pane = "create"
      root.selectedId = ""
      root.draft = null
    } else if (id !== "") {
      selectMode(id)
    } else if (modes.length > 0) {
      selectMode(modes[0].id)
    } else {
      root.pane = "create"
    }
    root.opened = true
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
    guard(function() {
      root.pane = "create"
      root.draft = null
      root.selectedId = ""
    })
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

  function openAppPicker() {
    root.appPickerOpen = true
    appPicker.reset()
  }

  function addDesktopApplication(desktopId) {
    root.appPickerOpen = false
    if (!desktopId) return
    pushDraftList("applications", { desktopId: String(desktopId), command: "", enabled: true })
  }

  function addCustomApplication() {
    root.appPickerOpen = false
    pushDraftList("applications", { desktopId: "", command: "", enabled: true })
  }

  function applicationName(app) {
    if (!app) return ""
    if (!app.desktopId) return String(app.command || "")
    var entry = service ? service.desktopEntry(app.desktopId) : null
    if (entry) return String(entry.name || app.desktopId)
    return String(app.desktopId) + "  (not installed)"
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
    else root.pane = "create"
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
    root.pane = modes.length > 0 ? "edit" : "create"
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
        root.writeExport(dir + "/omara-export.json", root.service.exportText(null))
      }
    }
  }

  // ------------------------------------------------------------------ window

  PanelWindow {
    visible: root.opened && !root.suspended
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omara-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

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
        if (modeForm.visible) {
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
        } else if (event.key === Qt.Key_D && root.pane === "edit" && root.draft) {
          root.duplicateSelected()
          event.accepted = true
        }
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(64), Style.space(860))
        // Sized to what is in it, within reason, so the first-run screen is not
        // a small list floating in a large empty box.
        readonly property real contentHeight: Style.space(150)
          + Math.max(detailColumn.implicitHeight, sidebarColumn.implicitHeight + Style.space(150))
        height: Math.min(parent.height - Style.space(64),
          Math.max(Style.space(320), Math.min(Style.space(680), contentHeight)))
        radius: Style.cornerRadius
        color: root.background
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: Color.popups.border

        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.panelGap

          // ------------------------------------------------------ header
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            Text {
              text: "Omara"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.service && root.service.activeMode
                ? "Active: " + root.service.activeMode.name : "No mode active"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              text: "Activity"
              foreground: root.foreground
              fontFamily: root.fontFamily
              selected: root.pane === "log"
              focusable: true
              onClicked: root.requestPane(root.pane === "log" ? "edit" : "log")
            }

            Button {
              text: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              selected: root.pane === "settings"
              focusable: true
              onClicked: root.requestPane(root.pane === "settings" ? "edit" : "settings")
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

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // ------------------------------------------------------- body
          RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.spacing.panelGap

            // ------------------------------------------------ sidebar
            ColumnLayout {
              Layout.fillWidth: false
              Layout.minimumWidth: Style.space(170)
              Layout.preferredWidth: Style.space(210)
              Layout.maximumWidth: Style.space(210)
              Layout.fillHeight: true
              spacing: Style.space(6)

              Flickable {
                id: sidebarFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: sidebarColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: sidebarColumn
                  width: sidebarFlick.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.modes

                    ModeRow {
                      required property var modelData
                      width: sidebarColumn.width
                      mode: modelData
                      isActive: root.service && root.service.activeModeId === modelData.id
                      hasCursor: root.selectedId === modelData.id
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      reorderable: true
                      onClicked: root.requestSelect(modelData.id)
                      onEditRequested: root.requestSelect(modelData.id)
                      onMoveRequested: function(delta) {
                        root.selectedId = modelData.id
                        root.moveSelected(delta)
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: root.modes.length === 0
                    wrapMode: Text.Wrap
                    text: "No modes yet."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

              Button {
                Layout.fillWidth: true
                iconText: Model.Glyph.add
                text: "New mode"
                leftAlign: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                focusable: true
                onClicked: root.requestCreateMode()
              }

              Button {
                Layout.fillWidth: true
                iconText: Model.Glyph.capture
                text: "Capture desktop"
                focusable: true
                leftAlign: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                Accessible.name: "Make a mode from the desktop as it is now"
                onClicked: root.captureDesktop()
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Button {
                  Layout.fillWidth: true
                  iconText: Model.Glyph.importFile
                  text: "Import"
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.browseImport()
                }

                Button {
                  Layout.fillWidth: true
                  iconText: Model.Glyph.exportFile
                  text: "Export"
                  focusable: true
                  enabled: root.modes.length > 0
                  foreground: root.modes.length > 0 ? root.foreground : root.dim
                  fontFamily: root.fontFamily
                  onClicked: root.exportAll()
                }
              }
            }

            Rectangle {
              Layout.preferredWidth: 1
              Layout.fillHeight: true
              color: Util.alpha(root.foreground, 0.12)
            }

            // --------------------------------------------------- detail
            Flickable {
              id: detailFlick
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              contentWidth: width
              contentHeight: detailColumn.implicitHeight
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: detailColumn
                width: detailFlick.width
                spacing: Style.space(12)

                // ------------------------------------------- templates
                Column {
                  width: parent.width
                  spacing: Style.space(8)
                  visible: root.pane === "create"

                  PanelSectionHeader { width: parent.width; text: "New mode"; foreground: root.foreground; fontFamily: root.fontFamily }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "Capture what is open right now, or start empty. Everything is editable afterwards."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Button {
                    width: detailColumn.width
                    leftAlign: true
                    bordered: true
                    iconText: Model.Glyph.capture
                    text: "Current desktop:  everything open right now"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.captureDesktop()
                  }

                  Button {
                    width: detailColumn.width
                    leftAlign: true
                    bordered: true
                    iconText: Model.Glyph.blank
                    text: "Blank:  an empty mode to fill in yourself"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.createFromTemplate("blank")
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
                      width: detailColumn.width
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
                          width: detailColumn.width - Style.space(16)
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

                      width: detailColumn.width
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
                      width: detailColumn.width
                      label: modelData.label
                      description: modelData.description
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      checked: root.service ? root.service.config.behavior[modelData.key] === true : false
                      onClicked: if (root.service) root.service.setBehavior(modelData.key, !checked)
                    }
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: "Config: ~/.config/omarchy/omara.json"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // ------------------------------------------------ form
                ModeForm {
                  id: modeForm
                  width: detailColumn.width
                  visible: root.pane === "edit" && root.draft !== null
                  editor: root
                }

                Text {
                  width: parent.width
                  visible: root.pane === "edit" && root.draft === null
                  wrapMode: Text.Wrap
                  text: "Pick a mode on the left, or create one."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          // ------------------------------------------------------ footer
          RowLayout {
            Layout.fillWidth: true
            visible: root.pane === "edit" && root.draft !== null
            spacing: Style.space(6)

            Button {
              iconText: Model.Glyph.remove
              text: "Delete"
              foreground: Color.urgent
              fontFamily: root.fontFamily
              focusable: true
              onClicked: deleteConfirm.opened = true
            }

            Button {
              iconText: Model.Glyph.duplicate
              text: "Duplicate"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              tooltipText: "Ctrl+D"
              onClicked: root.duplicateSelected()
            }

            Item { Layout.fillWidth: true }

            Text {
              visible: root.dirty
              text: "Unsaved changes"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              text: "Revert"
              focusable: true
              enabled: root.dirty
              foreground: root.dirty ? root.foreground : root.dim
              fontFamily: root.fontFamily
              onClicked: root.revertDraft()
            }

            Button {
              text: "Save"
              bordered: true
              focusable: true
              tooltipText: "Ctrl+S"
              enabled: root.dirty
              foreground: root.dirty ? root.foreground : root.dim
              fontFamily: root.fontFamily
              onClicked: root.saveDraft()
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

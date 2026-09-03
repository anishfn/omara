import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The workspace editor: what a mode opens, laid out the way it will sit on
// screen. A tab is one workspace, a pane is one application, and dragging is
// how both are arranged.
//
// Every rectangle drawn here is one Model.paneRects computed, and hit testing
// reads the same array, so what the pointer lands on is always what the eye
// lands on. Dragging is done by hand rather than with Drag/DropArea: the drag
// crosses three surfaces (the list, the tabs, the board) and a manual grab is
// the only way the tab under the pointer can switch mid-drag.
Item {
  id: canvas

  required property var editor

  readonly property var draft: editor ? editor.draft : null
  readonly property var service: editor ? editor.service : null
  readonly property var appLibrary: service ? service.appLibrary : null
  readonly property color foreground: editor ? editor.foreground : Color.foreground
  readonly property color dim: editor ? editor.dim : Qt.darker(Color.foreground, 1.5)
  readonly property string fontFamily: editor ? editor.fontFamily : Style.font.family

  readonly property var layouts: editor ? editor.layouts : []

  property int tab: 0
  property string selectedPath: ""
  property string query: ""

  // The tab currently being renamed in place, or -1. A tab is a button until
  // you click the one you are already on, and a field after that.
  property int renaming: -1

  // The tab currently being dragged to a new position, or -1. It tracks the
  // slot the tab is in rather than the one it started in, because the tabs
  // swap under the pointer as it crosses them.
  property int reordering: -1

  // The counted tab Repeater indexes this rather than holding the array, so a
  // reorder cannot destroy the delegate mid-drag.
  function layoutAt(i) {
    var list = canvas.layouts
    return (i >= 0 && i < list.length) ? list[i] : { workspace: "", tree: Model.paneLeaf("") }
  }

  // The space between panes is space. Wide enough to read as a gap rather
  // than a seam, and nothing is drawn in it until you reach for it.
  readonly property int gap: Style.space(8)

  readonly property var tree: (tab >= 0 && tab < layouts.length) ? layouts[tab].tree : Model.paneLeaf("")
  readonly property var rects: Model.paneRects(tree, board.width, board.height, canvas.gap)

  // The Repeaters below count these rather than iterate them. A resize
  // rewrites the tree on every mouse move, which makes paneRects hand back a
  // fresh array each time; a Repeater told to model that array throws away its
  // delegates and builds new ones, and the divider you were dragging is
  // destroyed mid-drag along with the grab it was holding. Counting keeps the
  // delegates alive across a resize and only rebuilds when a pane is added or
  // removed, which is the only time the count actually changes.
  readonly property var voidRect: ({
    path: "", app: "", direction: "row",
    x: 0, y: 0, width: 0, height: 0,
    spanX: 0, spanY: 0, spanWidth: 0, spanHeight: 0
  })

  function paneRect(i) {
    var list = canvas.rects.panes
    return (i >= 0 && i < list.length) ? list[i] : canvas.voidRect
  }

  function dividerRect(i) {
    var list = canvas.rects.dividers
    return (i >= 0 && i < list.length) ? list[i] : canvas.voidRect
  }

  readonly property string landing: draft && draft.workspaces && draft.workspaces.target !== null
    && draft.workspaces.target !== undefined ? String(draft.workspaces.target) : ""

  // A layout can go away under the tab index — a delete, a revert, a different
  // mode — so the index is clamped where it is read from, not where it is set.
  onLayoutsChanged: {
    if (tab >= layouts.length) tab = Math.max(0, layouts.length - 1)
    if (renaming >= layouts.length) renaming = -1
    if (reordering >= layouts.length) reordering = -1
    if (Model.paneAt(canvas.tree, canvas.selectedPath) === null) canvas.selectedPath = ""
  }

  // A different mode is a different set of workspaces; nothing about the last
  // one should still be selected, being renamed, or half dragged.
  //
  // Keyed on the mode's id, not on the draft object. The draft is replaced on
  // every edit — a resize replaces it on every mouse move — so watching the
  // object itself meant each of those counted as switching modes: the pane you
  // had selected was deselected, and a drag in progress was cancelled under
  // you the moment it changed anything.
  readonly property string modeId: draft ? String(draft.id) : ""

  onModeIdChanged: {
    canvas.tab = 0
    canvas.renaming = -1
    canvas.reordering = -1
    canvas.selectedPath = ""
    canvas.dragCancel()
  }

  // ------------------------------------------------------------- hit testing

  function paneUnder(x, y) {
    var panes = canvas.rects.panes
    for (var i = 0; i < panes.length; i++) {
      var p = panes[i]
      if (x >= p.x && x <= p.x + p.width && y >= p.y && y <= p.y + p.height) return p
    }
    return null
  }

  // Which edge of a pane the pointer came in from. The middle means "put it
  // here"; an edge means "split this pane and put it on that side". An empty
  // pane has nothing to split, so all of it is the middle.
  function zoneFor(pane, x, y) {
    if (!pane || pane.app === "") return "center"
    var rx = (x - pane.x) / Math.max(1, pane.width)
    var ry = (y - pane.y) / Math.max(1, pane.height)
    var edge = 0.33
    var fromLeft = rx, fromRight = 1 - rx, fromTop = ry, fromBottom = 1 - ry
    var nearest = Math.min(fromLeft, fromRight, fromTop, fromBottom)
    if (nearest > edge) return "center"
    if (nearest === fromLeft) return "left"
    if (nearest === fromRight) return "right"
    if (nearest === fromTop) return "top"
    return "bottom"
  }

  function tabUnder(x, y) {
    for (var i = 0; i < tabRepeater.count; i++) {
      var item = tabRepeater.itemAt(i)
      if (!item) continue
      var p = item.mapFromItem(canvas, x, y)
      if (p.x >= 0 && p.x <= item.width && p.y >= 0 && p.y <= item.height) return i
    }
    return -1
  }

  // ---------------------------------------------------------------- dragging

  property bool dragging: false
  property string dragDesktopId: ""
  property string dragUid: ""
  property int dragFromTab: -1
  property string dragFromPath: ""
  property string dragLabel: ""
  property string dragIcon: ""
  property real dragX: 0
  property real dragY: 0

  property bool overPane: false
  property string hoverPath: ""
  property string hoverZone: "center"

  // The pane the pointer is simply resting on, which is what puts that pane's
  // controls on screen. Tracked with a HoverHandler rather than the board's
  // MouseArea because the controls sit above that MouseArea, and hovering one
  // of them would otherwise read as having left the pane it belongs to.
  property string pointerPath: ""

  function startEntryDrag(entry) {
    canvas.dragUid = ""
    canvas.dragFromTab = -1
    canvas.dragDesktopId = String(entry && entry.id ? entry.id : "")
    canvas.dragLabel = appLibrary ? appLibrary.entryName(entry) : canvas.dragDesktopId
    canvas.dragIcon = appLibrary ? appLibrary.iconSource(String(entry && entry.icon ? entry.icon : "")) : ""
    canvas.dragging = canvas.dragDesktopId !== ""
  }

  function startPaneDrag(path, uid) {
    var app = editor.applicationByUid(uid)
    if (!app) return
    canvas.dragDesktopId = ""
    canvas.dragUid = String(uid)
    canvas.dragFromTab = canvas.tab
    canvas.dragFromPath = String(path)
    canvas.dragLabel = editor.applicationName(app)
    canvas.dragIcon = editor.applicationIcon(app)
    canvas.dragging = true
  }

  function dragMove(x, y) {
    if (!canvas.dragging) return
    canvas.dragX = x
    canvas.dragY = y
    var over = canvas.tabUnder(x, y)
    if (over >= 0 && over !== canvas.tab) {
      canvas.tab = over
      canvas.renaming = -1
    }
    var local = board.mapFromItem(canvas, x, y)
    var pane = canvas.paneUnder(local.x, local.y)
    canvas.overPane = pane !== null
    canvas.hoverPath = pane ? pane.path : ""
    canvas.hoverZone = pane ? canvas.zoneFor(pane, local.x, local.y) : "center"
  }

  function dragDrop(x, y) {
    canvas.dragMove(x, y)
    if (canvas.dragging && canvas.overPane) {
      if (canvas.dragDesktopId !== "")
        editor.placeApplication(canvas.tab, canvas.hoverPath, canvas.hoverZone,
          { desktopId: canvas.dragDesktopId, command: "", enabled: true })
      else if (canvas.dragUid !== "")
        editor.movePaneApp(canvas.dragFromTab, canvas.dragFromPath,
          canvas.tab, canvas.hoverPath, canvas.hoverZone)
      canvas.selectedPath = canvas.hoverPath
    }
    canvas.dragCancel()
  }

  function dragCancel() {
    canvas.dragging = false
    canvas.dragDesktopId = ""
    canvas.dragUid = ""
    canvas.dragFromTab = -1
    canvas.dragFromPath = ""
    canvas.overPane = false
    canvas.hoverPath = ""
  }

  // ------------------------------------------------------------------ adding

  function addEntry(entry) {
    if (!entry || !entry.id) return
    editor.placeApplication(canvas.tab, canvas.selectedPath, "center",
      { desktopId: String(entry.id), command: "", enabled: true })
  }
  // ------------------------------------------------------------------ layout

  ColumnLayout {
    id: column
    anchors.fill: parent
    spacing: Style.space(8)

    // ------------------------------------------------------- workspace tabs
    //
    // One tab per workspace, sharing the width the way the workspaces share
    // the desktop. Clicking the tab you are already on turns it into the
    // field that names it, so a workspace is renamed where it is read.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(4)

      Repeater {
        id: tabRepeater
        // Counted, not iterated. Reordering hands back a fresh array, and a
        // Repeater modelled on the array would rebuild every delegate — taking
        // the mouse grab of the tab being dragged with it, one tab into the
        // drag. Counting keeps them alive; only adding or removing a workspace
        // changes the count.
        model: canvas.layouts.length

        Item {
          id: cell
          required property int index

          readonly property var modelData: canvas.layoutAt(index)
          readonly property bool editing: canvas.renaming === index
          readonly property bool isLanding: canvas.landing !== "" && canvas.landing === modelData.workspace

          opacity: canvas.reordering === index ? 0.65 : 1

          // Wide enough to read, narrow enough that one workspace does not
          // look like a title bar. They share the leftover room between them
          // and stop growing well before the board does.
          Layout.fillWidth: true
          Layout.preferredWidth: Style.space(64)
          Layout.maximumWidth: Style.space(96)
          Layout.preferredHeight: tabField.implicitHeight

          Button {
            anchors.fill: parent
            visible: !parent.editing
            text: modelData.workspace === "" ? "Any" : modelData.workspace
            bordered: true
            focusable: true
            selected: canvas.tab === index
            foreground: canvas.foreground
            fontFamily: canvas.fontFamily
            hasCursor: tabMouse.containsMouse
            tooltipText: modelData.workspace === ""
              ? "Opens wherever you happen to be  ·  drag to reorder"
              : "Click again to rename  ·  drag to reorder"
            Accessible.name: modelData.workspace === "" ? "Any workspace" : "Workspace " + modelData.workspace
            Accessible.onPressAction: canvas.tab = cell.index

            Rectangle {
              visible: cell.isLanding
              width: Style.space(5)
              height: width
              radius: width / 2
              color: Color.accent
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(3)
            }
          }

          // Above the button, below the field. The button is chrome now; every
          // gesture a tab answers to is here, because a click and the start of
          // a drag are the same event until the pointer has moved.
          MouseArea {
            id: tabMouse
            anchors.fill: parent
            enabled: !cell.editing
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            preventStealing: true

            property real pressX: 0
            property bool armed: false
            property bool moving: false

            onPressed: function(mouse) {
              tabMouse.pressX = mouse.x
              tabMouse.armed = true
              tabMouse.moving = false
            }

            onPositionChanged: function(mouse) {
              if (!tabMouse.armed) return
              if (!tabMouse.moving) {
                if (Math.abs(mouse.x - tabMouse.pressX) < Style.space(8)) return
                tabMouse.moving = true
                canvas.renaming = -1
                canvas.tab = cell.index
                canvas.reordering = cell.index
              }
              // Swap as the pointer crosses a neighbour rather than on release:
              // the tabs moving under the pointer is the only feedback needed.
              var at = canvas.mapFromItem(tabMouse, mouse.x, mouse.y)
              var over = canvas.tabUnder(at.x, at.y)
              if (over >= 0 && over !== canvas.reordering) {
                canvas.editor.moveWorkspace(canvas.reordering, over)
                canvas.reordering = over
                canvas.tab = over
              }
            }

            onReleased: {
              if (tabMouse.armed && !tabMouse.moving) {
                if (canvas.tab === cell.index) {
                  canvas.renaming = cell.index
                } else {
                  canvas.tab = cell.index
                  canvas.selectedPath = ""
                  canvas.renaming = -1
                }
              }
              tabMouse.armed = false
              tabMouse.moving = false
              canvas.reordering = -1
            }

            onCanceled: {
              tabMouse.armed = false
              tabMouse.moving = false
              canvas.reordering = -1
            }
          }

          TextField {
            id: tabField
            anchors.fill: parent
            visible: cell.editing
            horizontalAlignment: TextInput.AlignHCenter
            placeholderText: "blank = anywhere"
            foreground: canvas.foreground
            Accessible.name: "Name this workspace"

            onVisibleChanged: if (visible) {
              text = modelData.workspace
              forceActiveFocus()
              selectAll()
            }

            // A name Hyprland cannot use, or one another tab already has, is
            // refused rather than half-applied; the field going back to what
            // it was is what says so.
            onEditingFinished: {
              if (!canvas.editor.renameWorkspace(index, text)) text = modelData.workspace
              canvas.renaming = -1
            }
            Keys.onEscapePressed: canvas.renaming = -1
          }
        }
      }

      Button {
        iconText: Model.Glyph.add
        tooltipText: "Add a workspace"
        focusable: true
        foreground: canvas.foreground
        fontFamily: canvas.fontFamily
        enabled: canvas.layouts.length < Model.MAX_LAYOUTS
        Accessible.name: "Add a workspace"
        bordered: true
        onClicked: {
          var index = canvas.editor.addWorkspace()
          if (index >= 0) {
            canvas.tab = index
            canvas.selectedPath = ""
            canvas.renaming = -1
          }
        }
      }

      Item { Layout.preferredWidth: Style.space(8); Layout.preferredHeight: 1 }

      Button {
        iconText: Model.Glyph.landing
        tooltipText: "Leave you on this workspace once the mode is up"
        focusable: true
        enabled: canvas.tab >= 0 && canvas.tab < canvas.layouts.length
          && canvas.layouts[canvas.tab].workspace !== ""
        selected: canvas.tab >= 0 && canvas.tab < canvas.layouts.length
          && canvas.landing !== "" && canvas.landing === canvas.layouts[canvas.tab].workspace
        foreground: enabled ? canvas.foreground : canvas.dim
        fontFamily: canvas.fontFamily
        Accessible.name: "Land on this workspace"
        bordered: true
        onClicked: canvas.editor.setLandingWorkspace(selected ? "" : canvas.layouts[canvas.tab].workspace)
      }

      Button {
        iconText: Model.Glyph.remove
        tooltipText: "Remove this workspace and everything on it"
        focusable: true
        enabled: canvas.layouts.length > 1
        foreground: enabled ? Color.urgent : canvas.dim
        fontFamily: canvas.fontFamily
        Accessible.name: "Remove this workspace"
        bordered: true
        onClicked: {
          canvas.renaming = -1
          canvas.editor.removeWorkspace(canvas.tab)
        }
      }

      Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
    }

    // -------------------------------------------------- applications | board
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Style.space(10)

      // ----------------------------------------------------------- app list
      ColumnLayout {
        id: picker
        Layout.fillHeight: true
        Layout.preferredWidth: Style.space(200)
        Layout.maximumWidth: Style.space(200)
        spacing: Style.space(6)

        TextField {
          Layout.fillWidth: true
          placeholderText: "Search apps…"
          foreground: canvas.foreground
          Accessible.name: "Search installed applications"
          onTextChanged: canvas.query = text
        }

        ListView {
          id: appList
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(1)
          boundsBehavior: Flickable.StopAtBounds
          model: canvas.appLibrary ? canvas.appLibrary.sortedEntries(canvas.query) : []

          delegate: Item {
            id: appRow
            required property var modelData
            readonly property var entry: modelData.entry

            width: appList.width
            height: Style.space(30)

            Accessible.role: Accessible.ListItem
            Accessible.name: canvas.appLibrary ? canvas.appLibrary.entryName(appRow.entry) : ""
            Accessible.onPressAction: canvas.addEntry(appRow.entry)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: appDrag.containsMouse
                ? Style.hoverFillFor(canvas.foreground, Color.accent, Color.accent) : "transparent"
            }

            Image {
              id: rowIcon
              width: Style.font.icon
              height: Style.font.icon
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: canvas.appLibrary
                ? canvas.appLibrary.iconSource(String(appRow.entry.icon || "")) : ""
              asynchronous: true
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              anchors.left: rowIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: canvas.appLibrary ? canvas.appLibrary.entryName(appRow.entry) : ""
              color: canvas.foreground
              font.family: canvas.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            MouseArea {
              id: appDrag
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              preventStealing: true

              property real pressX: 0
              property real pressY: 0
              property bool armed: false

              onPressed: function(mouse) {
                appDrag.pressX = mouse.x
                appDrag.pressY = mouse.y
                appDrag.armed = true
              }

              onPositionChanged: function(mouse) {
                if (!appDrag.armed) return
                if (!canvas.dragging) {
                  if (Math.abs(mouse.x - appDrag.pressX) + Math.abs(mouse.y - appDrag.pressY) < Style.space(6)) return
                  canvas.startEntryDrag(appRow.entry)
                }
                var p = canvas.mapFromItem(appDrag, mouse.x, mouse.y)
                canvas.dragMove(p.x, p.y)
              }

              onReleased: function(mouse) {
                if (canvas.dragging) {
                  var p = canvas.mapFromItem(appDrag, mouse.x, mouse.y)
                  canvas.dragDrop(p.x, p.y)
                } else if (appDrag.armed) {
                  // A plain click still works: it goes into the selected pane,
                  // which is the whole board when nothing is selected.
                  canvas.addEntry(appRow.entry)
                }
                appDrag.armed = false
              }

              onCanceled: {
                appDrag.armed = false
                canvas.dragCancel()
              }
            }
          }
        }
      }

      // -------------------------------------------------------------- board
      Rectangle {
        id: boardFrame
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: Style.cornerRadius
        // The panes are the objects. The board they sit on is only a region,
        // so it draws nothing until there is something to catch.
        color: "transparent"
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: Util.alpha(Color.accent, canvas.dragging ? 0.45 : 0)
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Item {
          id: board
          anchors.fill: parent
          anchors.margins: Style.space(6)

          // ------------------------------------------------------- panes
          Repeater {
            model: canvas.rects.panes.length

            Rectangle {
              required property int index

              readonly property var modelData: canvas.paneRect(index)
              readonly property var app: canvas.editor.applicationByUid(modelData.app)
              readonly property bool chosen: canvas.selectedPath === modelData.path
              readonly property bool targeted: canvas.dragging && canvas.overPane
                && canvas.hoverPath === modelData.path
              readonly property bool off: app && app.enabled === false

              x: modelData.x
              y: modelData.y
              width: modelData.width
              height: modelData.height
              radius: Style.cornerRadius
              color: modelData.app === ""
                ? Util.alpha(canvas.foreground, 0.02)
                : Util.alpha(canvas.foreground, off ? 0.04 : 0.09)
              border.width: Math.max(1, Style.normalBorderWidth)
              border.color: chosen ? Util.alpha(Color.accent, 0.8)
                : Util.alpha(canvas.foreground,
                    canvas.pointerPath === modelData.path ? 0.4
                      : (modelData.app === "" ? 0.12 : 0.22))
              // A pane is as big as it is. Its contents do not get to spill
              // into the pane beside it when the split leaves it narrow.
              clip: true

              Accessible.role: Accessible.Pane
              Accessible.name: modelData.app === "" ? "Empty pane" : canvas.editor.applicationName(app)

              Behavior on color { ColorAnimation { duration: 100 } }

              // Where a drop would land, drawn as the shape the pane would
              // take rather than as a badge that has to be read.
              Rectangle {
                visible: parent.targeted
                radius: Style.cornerRadius
                color: Util.alpha(Color.accent, 0.28)
                border.width: Math.max(1, Style.normalBorderWidth)
                border.color: Util.alpha(Color.accent, 0.9)
                x: canvas.hoverZone === "right" ? parent.width / 2 : 0
                y: canvas.hoverZone === "bottom" ? parent.height / 2 : 0
                width: (canvas.hoverZone === "left" || canvas.hoverZone === "right")
                  ? parent.width / 2 : parent.width
                height: (canvas.hoverZone === "top" || canvas.hoverZone === "bottom")
                  ? parent.height / 2 : parent.height
              }

              Column {
                anchors.centerIn: parent
                width: parent.width - Style.space(12)
                spacing: Style.space(4)
                visible: modelData.app !== ""
                opacity: parent.off ? 0.45 : 1

                Image {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.font.iconLarge
                  height: Style.font.iconLarge
                  visible: parent.parent.height > Style.space(56) && source !== ""
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  source: canvas.editor.applicationIcon(parent.parent.app)
                  asynchronous: true
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: canvas.editor.applicationName(parent.parent.app)
                  color: canvas.foreground
                  font.family: canvas.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                // A custom command is edited where it runs, not in a list
                // somewhere else — but only once you have picked the pane, so
                // a board of them is a board of names rather than of inputs.
                TextField {
                  width: parent.width
                  visible: parent.parent.chosen && parent.parent.app
                    && !parent.parent.app.desktopId
                    && parent.parent.width > Style.space(160)
                    && parent.parent.height > Style.space(96)
                  text: parent.parent.app ? String(parent.parent.app.command || "") : ""
                  placeholderText: "Command"
                  foreground: canvas.foreground
                  Accessible.name: "Application command"
                  onEditingFinished: canvas.editor.setApplicationField(modelData.app, "command", text)
                }
              }

              Column {
                anchors.centerIn: parent
                width: parent.width - Style.space(12)
                visible: modelData.app === ""
                spacing: Style.space(2)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: Model.Glyph.add
                  color: canvas.dim
                  font.family: canvas.fontFamily
                  font.pixelSize: Style.font.iconLarge
                }

                Text {
                  width: parent.width
                  visible: parent.parent.height > Style.space(64)
                  horizontalAlignment: Text.AlignHCenter
                  text: "drop an app here"
                  color: canvas.dim
                  font.family: canvas.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          // Below the dividers and the pane controls on purpose: those are
          // declared after, so the pointer reaches them first.
          MouseArea {
            id: boardMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton

            property real pressX: 0
            property real pressY: 0
            property string pressPath: ""
            property bool armed: false

            onPressed: function(mouse) {
              var pane = canvas.paneUnder(mouse.x, mouse.y)
              boardMouse.pressX = mouse.x
              boardMouse.pressY = mouse.y
              boardMouse.pressPath = pane ? pane.path : ""
              boardMouse.armed = pane !== null
              if (pane) canvas.selectedPath = pane.path
            }

            onPositionChanged: function(mouse) {
              if (!boardMouse.armed) return
              if (!canvas.dragging) {
                if (Math.abs(mouse.x - boardMouse.pressX) + Math.abs(mouse.y - boardMouse.pressY) < Style.space(6)) return
                var node = Model.paneAt(canvas.tree, boardMouse.pressPath)
                if (!node || node.app === "") { boardMouse.armed = false; return }
                canvas.startPaneDrag(boardMouse.pressPath, node.app)
              }
              var p = canvas.mapFromItem(boardMouse, mouse.x, mouse.y)
              canvas.dragMove(p.x, p.y)
            }

            onReleased: function(mouse) {
              if (canvas.dragging) {
                var p = canvas.mapFromItem(boardMouse, mouse.x, mouse.y)
                canvas.dragDrop(p.x, p.y)
                boardMouse.armed = false
                return
              }
              // An empty pane is a slot with nothing to select, so a click on
              // one asks what goes in it rather than quietly highlighting it.
              var pane = canvas.paneUnder(mouse.x, mouse.y)
              if (boardMouse.armed && pane && pane.app === "" && pane.path === boardMouse.pressPath)
                canvas.editor.openAppPicker(canvas.tab, pane.path)
              boardMouse.armed = false
            }

            onCanceled: {
              boardMouse.armed = false
              canvas.dragCancel()
            }

            onDoubleClicked: function(mouse) {
              var pane = canvas.paneUnder(mouse.x, mouse.y)
              if (pane) canvas.editor.openAppPicker(canvas.tab, pane.path)
            }
          }

          HoverHandler {
            id: boardHover
            onPointChanged: {
              var at = boardHover.point.position
              var pane = canvas.paneUnder(at.x, at.y)
              canvas.pointerPath = pane ? pane.path : ""
            }
            onHoveredChanged: if (!hovered) canvas.pointerPath = ""
          }

          // ---------------------------------------------------- dividers
          Repeater {
            model: canvas.rects.dividers.length

            Item {
              required property int index

              readonly property var modelData: canvas.dividerRect(index)

              // The grab area is wider than the line, so a thin divider is
              // still something a pointer can catch.
              readonly property int reach: Style.space(4)

              x: modelData.x - (modelData.direction === "row" ? reach : 0)
              y: modelData.y - (modelData.direction === "column" ? reach : 0)
              width: modelData.width + (modelData.direction === "row" ? reach * 2 : 0)
              height: modelData.height + (modelData.direction === "column" ? reach * 2 : 0)

              // A short grip in the middle of the gap, and only while the
              // pointer is on it. A line drawn down every seam made a layout
              // of four panes look like a table of contents.
              Rectangle {
                anchors.centerIn: parent
                width: modelData.direction === "row" ? Style.space(3) : Style.space(24)
                height: modelData.direction === "row" ? Style.space(24) : Style.space(3)
                radius: Math.min(width, height) / 2
                color: Util.alpha(canvas.foreground, 0.55)
                opacity: grip.containsMouse || grip.pressed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 90 } }
              }

              MouseArea {
                id: grip
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: modelData.direction === "row" ? Qt.SplitHCursor : Qt.SplitVCursor
                Accessible.role: Accessible.Separator
                Accessible.name: "Resize these panes"

                onPositionChanged: function(mouse) {
                  if (!grip.pressed) return
                  var p = board.mapFromItem(grip, mouse.x, mouse.y)
                  var ratio = modelData.direction === "column"
                    ? (p.y - modelData.spanY) / Math.max(1, modelData.spanHeight - canvas.gap)
                    : (p.x - modelData.spanX) / Math.max(1, modelData.spanWidth - canvas.gap)
                  canvas.editor.setPaneRatio(canvas.tab, modelData.path, ratio)
                }
              }
            }
          }

          // ------------------------------------------------ pane controls
          Repeater {
            model: canvas.rects.panes.length

            Row {
              required property int index

              readonly property var modelData: canvas.paneRect(index)

              // Only on a pane with something in it: an empty pane has nothing
              // to split, nothing to skip, and closing it is what dropping an
              // application into it undoes anyway.
              readonly property bool shown: !canvas.dragging && modelData.app !== ""
                && (canvas.selectedPath === modelData.path || canvas.pointerPath === modelData.path)
                && modelData.width > Style.space(90) && modelData.height > Style.space(40)

              x: modelData.x + modelData.width - width - Style.space(6)
              y: modelData.y + Style.space(6)
              visible: shown
              spacing: Style.space(2)

              PanelActionButton {
                iconText: Model.Glyph.splitVertical
                tooltipText: "Split left and right"
                size: Style.space(20)
                fontSize: Style.font.caption
                foreground: canvas.foreground
                fontFamily: canvas.fontFamily
                onClicked: canvas.editor.splitPane(canvas.tab, modelData.path, "row")
              }

              PanelActionButton {
                iconText: Model.Glyph.splitHorizontal
                tooltipText: "Split top and bottom"
                size: Style.space(20)
                fontSize: Style.font.caption
                foreground: canvas.foreground
                fontFamily: canvas.fontFamily
                onClicked: canvas.editor.splitPane(canvas.tab, modelData.path, "column")
              }

              PanelActionButton {
                iconText: Model.Glyph.close
                tooltipText: "Close this pane"
                size: Style.space(20)
                fontSize: Style.font.caption
                foreground: canvas.foreground
                fontFamily: canvas.fontFamily
                onClicked: {
                  canvas.selectedPath = ""
                  canvas.editor.closePane(canvas.tab, modelData.path)
                }
              }
            }
          }
        }
      }
    }

    // --------------------------------------------------------------- legend
    Text {
      Layout.fillWidth: true
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      // The first clause is the one a new mode needs: the tabs are not a
      // toolbar, they are the workspaces this mode opens on.
      text: "Each tab is a workspace, drag one to reorder  ·  drag an app in "
        + "from the left  ·  drop one on a pane's edge to split it  ·  "
        + "drag a divider to resize"
      color: canvas.dim
      font.family: canvas.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ----------------------------------------------------------------- ghost
  //
  // Outside the column so it does not take a row in it, and above everything
  // so it is never clipped by the board it is being dragged across.
  Rectangle {
    id: ghost
    visible: canvas.dragging
    z: 50
    x: canvas.dragX + Style.space(10)
    y: canvas.dragY - Style.space(10)
    width: ghostRow.implicitWidth + Style.space(16)
    height: ghostRow.implicitHeight + Style.space(10)
    radius: Style.cornerRadius
    color: Util.alpha(Color.background, 0.95)
    border.width: Math.max(1, Style.normalBorderWidth)
    border.color: Util.alpha(Color.accent, 0.8)

    Row {
      id: ghostRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Image {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.icon
        height: Style.font.icon
        visible: source !== ""
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: canvas.dragIcon
        asynchronous: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: canvas.dragLabel
        color: canvas.foreground
        font.family: canvas.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}

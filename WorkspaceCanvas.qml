import QtQuick
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

  readonly property int boardHeight: Style.space(250)
  readonly property int gap: Math.max(3, Style.space(4))

  readonly property var tree: (tab >= 0 && tab < layouts.length) ? layouts[tab].tree : Model.paneLeaf("")
  readonly property var rects: Model.paneRects(tree, board.width, board.height, canvas.gap)

  readonly property string landing: draft && draft.workspaces && draft.workspaces.target !== null
    && draft.workspaces.target !== undefined ? String(draft.workspaces.target) : ""

  height: column.implicitHeight

  // A layout can go away under the tab index — a delete, a revert, a different
  // mode — so the index is clamped where it is read from, not where it is set.
  onLayoutsChanged: {
    if (tab >= layouts.length) tab = Math.max(0, layouts.length - 1)
    if (Model.paneAt(canvas.tree, canvas.selectedPath) === null) canvas.selectedPath = ""
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
    if (over >= 0 && over !== canvas.tab) canvas.tab = over
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

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(8)

    // ------------------------------------------------------- workspace tabs
    Row {
      id: tabsRow
      width: column.width
      spacing: Style.space(4)

      Repeater {
        id: tabRepeater
        model: canvas.layouts

        Button {
          required property var modelData
          required property int index

          readonly property bool isLanding: canvas.landing !== "" && canvas.landing === modelData.workspace

          text: modelData.workspace === "" ? "Any" : modelData.workspace
          bordered: true
          selected: canvas.tab === index
          focusable: true
          foreground: canvas.foreground
          fontFamily: canvas.fontFamily
          tooltipText: modelData.workspace === ""
            ? "Opens wherever you happen to be"
            : (isLanding ? "Workspace " + modelData.workspace + "  ·  you land here"
                         : "Workspace " + modelData.workspace)
          Accessible.name: modelData.workspace === "" ? "Any workspace" : "Workspace " + modelData.workspace
          onClicked: {
            canvas.tab = index
            canvas.selectedPath = ""
          }

          // The landing workspace is marked on its own tab rather than named
          // again in a field somewhere else on the form.
          Rectangle {
            visible: parent.isLanding
            width: Style.space(5)
            height: width
            radius: width / 2
            color: Color.accent
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(3)
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
        onClicked: {
          var index = canvas.editor.addWorkspace()
          if (index >= 0) {
            canvas.tab = index
            canvas.selectedPath = ""
          }
        }
      }
    }

    // ------------------------------------------------- the workspace's tools
    Row {
      width: column.width
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Workspace"
        color: canvas.dim
        font.family: canvas.fontFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: workspaceField
        width: Style.space(120)
        anchors.verticalCenter: parent.verticalCenter
        enabled: canvas.tab >= 0 && canvas.tab < canvas.layouts.length
        text: canvas.tab >= 0 && canvas.tab < canvas.layouts.length ? canvas.layouts[canvas.tab].workspace : ""
        placeholderText: "blank = wherever you are"
        foreground: canvas.foreground
        Accessible.name: "Workspace this tab opens on"
        // A name Hyprland cannot use, or one another tab already has, is
        // refused rather than half-applied; putting the old value back is what
        // says so.
        onEditingFinished: {
          if (canvas.tab < 0 || canvas.tab >= canvas.layouts.length) return
          if (!canvas.editor.renameWorkspace(canvas.tab, text))
            text = canvas.layouts[canvas.tab].workspace
        }
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "Land here"
        bordered: true
        focusable: true
        enabled: canvas.tab >= 0 && canvas.tab < canvas.layouts.length
          && canvas.layouts[canvas.tab].workspace !== ""
        selected: canvas.tab >= 0 && canvas.tab < canvas.layouts.length
          && canvas.landing !== "" && canvas.landing === canvas.layouts[canvas.tab].workspace
        foreground: enabled ? canvas.foreground : canvas.dim
        fontFamily: canvas.fontFamily
        tooltipText: "Leave you on this workspace once the mode is up"
        Accessible.name: "Land on this workspace"
        onClicked: canvas.editor.setLandingWorkspace(selected ? "" : canvas.layouts[canvas.tab].workspace)
      }

      Item { width: Style.space(2); height: 1 }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.Glyph.remove
        tooltipText: "Remove this workspace and everything on it"
        focusable: true
        enabled: canvas.layouts.length > 1
        foreground: enabled ? Color.urgent : canvas.dim
        fontFamily: canvas.fontFamily
        Accessible.name: "Remove this workspace"
        onClicked: canvas.editor.removeWorkspace(canvas.tab)
      }
    }

    // --------------------------------------------------- applications | board
    Row {
      width: column.width
      height: canvas.boardHeight
      spacing: Style.space(10)

      // ----------------------------------------------------------- app list
      Column {
        id: picker
        width: Math.min(Style.space(210), Math.max(Style.space(140), parent.width * 0.3))
        height: parent.height
        spacing: Style.space(6)

        TextField {
          width: picker.width
          placeholderText: "Search apps…"
          foreground: canvas.foreground
          Accessible.name: "Search installed applications"
          onTextChanged: canvas.query = text
        }

        ListView {
          id: appList
          width: picker.width
          height: Math.max(0, picker.height - y)
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
        width: Math.max(0, parent.width - picker.width - parent.spacing)
        height: parent.height
        radius: Style.cornerRadius
        color: Util.alpha(canvas.foreground, 0.03)
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: Util.alpha(canvas.foreground, canvas.dragging ? 0.4 : 0.14)

        Item {
          id: board
          anchors.fill: parent
          anchors.margins: Style.space(6)

          // ------------------------------------------------------- panes
          Repeater {
            model: canvas.rects.panes

            Rectangle {
              required property var modelData

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
                // somewhere else. Desktop entries have nothing to type.
                TextField {
                  width: parent.width
                  visible: parent.parent.app && !parent.parent.app.desktopId
                    && parent.parent.width > Style.space(150)
                  text: parent.parent.app ? String(parent.parent.app.command || "") : ""
                  placeholderText: "Command"
                  foreground: canvas.foreground
                  Accessible.name: "Application command"
                  onEditingFinished: canvas.editor.setApplicationField(modelData.app, "command", text)
                }
              }

              Text {
                anchors.centerIn: parent
                visible: modelData.app === ""
                horizontalAlignment: Text.AlignHCenter
                text: Model.Glyph.add + "\ndrop an app"
                color: canvas.dim
                font.family: canvas.fontFamily
                font.pixelSize: Style.font.caption
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
              }
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
            model: canvas.rects.dividers

            Item {
              required property var modelData

              // The grab area is wider than the line, so a 4px divider is
              // still something a pointer can catch.
              readonly property int reach: Style.space(4)

              x: modelData.x - (modelData.direction === "row" ? reach : 0)
              y: modelData.y - (modelData.direction === "column" ? reach : 0)
              width: modelData.width + (modelData.direction === "row" ? reach * 2 : 0)
              height: modelData.height + (modelData.direction === "column" ? reach * 2 : 0)

              Rectangle {
                anchors.centerIn: parent
                width: modelData.direction === "row" ? Math.max(1, modelData.width) : parent.width
                height: modelData.direction === "column" ? Math.max(1, modelData.height) : parent.height
                radius: width < height ? width / 2 : height / 2
                color: Util.alpha(canvas.foreground, grip.containsMouse || grip.pressed ? 0.55 : 0.16)
                Behavior on color { ColorAnimation { duration: 90 } }
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
            model: canvas.rects.panes

            Row {
              required property var modelData

              readonly property bool shown: !canvas.dragging
                && (canvas.selectedPath === modelData.path || canvas.pointerPath === modelData.path)
                && modelData.width > Style.space(90) && modelData.height > Style.space(40)

              x: modelData.x + modelData.width - width - Style.space(4)
              y: modelData.y + Style.space(4)
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
                iconText: Model.Glyph.power
                tooltipText: "Open this one with the mode, or skip it"
                visible: modelData.app !== ""
                size: Style.space(20)
                fontSize: Style.font.caption
                foreground: canvas.foreground
                fontFamily: canvas.fontFamily
                onClicked: {
                  var app = canvas.editor.applicationByUid(modelData.app)
                  if (app) canvas.editor.setApplicationField(modelData.app, "enabled", app.enabled === false)
                }
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
      width: column.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "Drag an app in from the left  ·  drop it on a pane's edge to split it  ·  "
        + "drag a pane onto a tab to move it  ·  drag a divider to resize\n"
        + "Panes are the order things open in, read left to right. The tiling itself is Hyprland's."
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

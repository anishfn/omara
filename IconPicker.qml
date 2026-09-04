import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// What a mode is called and what it looks like, in one place: the two halves
// of its identity, which is also the one thing a chip in the tab row shows.
// Renaming lives here rather than in the options form because the chip is
// where you go looking for it.
//
// The glyph grid is laid out like Omarchy's emoji panel. Glyphs come from
// icons.json, which only contains ones the shipped menu already uses, so
// nothing in here renders as a tofu box.
Item {
  id: root

  required property var editor

  readonly property var draft: editor ? editor.draft : null
  readonly property color foreground: editor ? editor.foreground : Color.popups.text
  readonly property color background: editor ? editor.background : Color.popups.background
  readonly property color dim: editor ? editor.dim : Qt.darker(Color.popups.text, 1.5)
  readonly property string fontFamily: editor ? editor.fontFamily : Style.font.family

  property var icons: []
  property string query: ""
  property int cursor: 0

  readonly property int cellSize: Math.max(Style.space(46), Style.font.display + Style.spacing.lg)
  readonly property int columns: Math.max(1, Math.floor(grid.width / cellSize))

  readonly property var rows: {
    var needle = String(query || "").trim().toLowerCase()
    if (needle === "") return icons
    var out = []
    for (var i = 0; i < icons.length; i++)
      if (String(icons[i].k).indexOf(needle) !== -1) out.push(icons[i])
    return out
  }

  signal chosen(string glyph)
  signal cleared()
  signal dismissed()

  function reset() {
    query = ""
    cursor = 0
    if (icons.length === 0) iconFile.reload()
    // The name is the field with something already in it, and the reason to
    // open this on a mode that already has an icon.
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  // A TextField commits on editingFinished, which a hidden overlay never
  // reaches. Every way out of here goes through this first, so a name typed
  // and then dismissed with Escape is still the name you typed.
  function commitName() {
    if (!root.editor || !root.draft) return
    if (String(nameField.text) === String(root.draft.name || "")) return
    root.editor.setDraft("name", nameField.text)
  }

  function move(delta) {
    if (rows.length === 0) return
    var next = cursor + delta
    if (next < 0) next = 0
    if (next >= rows.length) next = rows.length - 1
    cursor = next
    grid.positionViewAtIndex(cursor, GridView.Contain)
  }

  function activate() {
    if (cursor < 0 || cursor >= rows.length) return
    root.commitName()
    root.chosen(String(rows[cursor].g))
  }

  onRowsChanged: cursor = 0

  FileView {
    id: iconFile
    path: Qt.resolvedUrl("icons.json").toString().replace("file://", "")
    watchChanges: false
    printErrors: false
    onLoaded: {
      try { root.icons = JSON.parse(this.text()) || [] } catch (e) { root.icons = [] }
    }
    onLoadFailed: root.icons = []
  }

  Component.onCompleted: iconFile.reload()

  MouseArea { anchors.fill: parent; onClicked: {} }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
    radius: Style.cornerRadius
  }

  Column {
    id: layout
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.space(10)

    Row {
      width: layout.width
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Mode"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Item { width: Math.max(0, layout.width - Style.space(300)); height: 1 }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "No icon"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: { root.commitName(); root.cleared() }
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.Glyph.close
        tooltipText: "Done"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Accessible.name: "Done"
        onClicked: { root.commitName(); root.dismissed() }
      }
    }

    Text {
      width: layout.width
      text: "Name"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: nameField
      width: layout.width
      text: root.draft ? String(root.draft.name || "") : ""
      placeholderText: "Name"
      foreground: root.foreground
      Accessible.name: "Mode name"
      onEditingFinished: root.commitName()

      // Enter hands the keyboard to the grid, which is the other half of what
      // this panel is for.
      Keys.onReturnPressed: { root.commitName(); search.forceActiveFocus() }
      Keys.onEnterPressed: { root.commitName(); search.forceActiveFocus() }
      Keys.onEscapePressed: { root.commitName(); root.dismissed() }
    }

    Text {
      width: layout.width
      text: "Icon"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: search
      width: layout.width
      placeholderText: "Search icons: code, game, focus, music..."
      foreground: root.foreground
      Accessible.name: "Search icons"
      onTextChanged: root.query = text

      Keys.onDownPressed: root.move(root.columns)
      Keys.onUpPressed: root.move(-root.columns)
      Keys.onRightPressed: root.move(1)
      Keys.onLeftPressed: root.move(-1)
      Keys.onReturnPressed: root.activate()
      Keys.onEnterPressed: root.activate()
      Keys.onEscapePressed: root.dismissed()
    }

    Text {
      width: layout.width
      visible: root.rows.length === 0
      wrapMode: Text.Wrap
      text: root.icons.length === 0 ? "Could not read icons.json." : "Nothing matches \"" + root.query + "\"."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    GridView {
      id: grid
      width: layout.width
      height: Math.max(0, layout.height - y)
      clip: true
      model: root.rows
      cellWidth: root.cellSize
      cellHeight: root.cellSize
      boundsBehavior: Flickable.StopAtBounds

      delegate: Rectangle {
        required property var modelData
        required property int index

        readonly property bool hot: index === root.cursor || hover.containsMouse

        width: root.cellSize
        height: root.cellSize
        radius: Style.cornerRadius
        color: hot ? Style.hoverFillFor(root.foreground, Color.accent, Color.accent) : "transparent"

        Accessible.role: Accessible.Button
        Accessible.name: String(modelData.k)
        Accessible.onPressAction: { root.commitName(); root.chosen(String(modelData.g)) }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: String(parent.modelData.g)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.cursor = index
          onClicked: { root.commitName(); root.chosen(String(parent.modelData.g)) }
        }
      }
    }
  }
}

import QtQuick
import qs.Commons
import "Model.js" as Model
import qs.Ui

// Installed Omarchy themes, from both the shipped and the user directory.
// A panel inside the editor card, not a window, so nothing can stack above it.
Item {
  id: root

  required property var editor

  readonly property var service: editor ? editor.service : null
  readonly property color foreground: editor ? editor.foreground : Color.popups.text
  readonly property color background: editor ? editor.background : Color.popups.background
  readonly property color dim: editor ? editor.dim : Qt.darker(Color.popups.text, 1.5)
  readonly property string fontFamily: editor ? editor.fontFamily : Style.font.family

  property string query: ""
  property int cursor: 0
  property string current: ""

  readonly property var rows: service ? Model.filterThemes(service.themes, query) : []

  signal chosen(string slug)
  signal cleared()
  signal dismissed()

  function reset(currentSlug) {
    root.current = String(currentSlug || "")
    query = ""
    cursor = 0
    if (service) service.refreshThemes()
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function move(delta) {
    if (rows.length === 0) return
    var next = cursor + delta
    if (next < 0) next = rows.length - 1
    if (next >= rows.length) next = 0
    cursor = next
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function activate() {
    if (cursor < 0 || cursor >= rows.length) return
    root.chosen(String(rows[cursor].slug))
  }

  onRowsChanged: cursor = 0

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
        text: "Choose a theme"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Item { width: Math.max(0, layout.width - Style.space(320)); height: 1 }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "Leave unchanged"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.cleared()
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.Glyph.close
        tooltipText: "Cancel"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.dismissed()
      }
    }

    TextField {
      id: search
      width: layout.width
      placeholderText: "Search installed themes"
      foreground: root.foreground
      Accessible.name: "Search installed themes"
      onTextChanged: root.query = text

      Keys.onDownPressed: root.move(1)
      Keys.onUpPressed: root.move(-1)
      Keys.onReturnPressed: root.activate()
      Keys.onEnterPressed: root.activate()
      Keys.onEscapePressed: root.dismissed()
    }

    Text {
      width: layout.width
      visible: root.rows.length === 0
      wrapMode: Text.Wrap
      text: root.query === "" ? "No themes found." : "Nothing matches \"" + root.query + "\"."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    ListView {
      id: list
      width: layout.width
      height: Math.max(0, layout.height - y)
      clip: true
      model: root.rows
      spacing: Style.space(2)
      boundsBehavior: Flickable.StopAtBounds

      delegate: Item {
        required property var modelData
        required property int index

        readonly property bool hot: index === root.cursor || hover.containsMouse
        readonly property bool isCurrent: String(modelData.slug) === root.current

        width: list.width
        height: Style.space(36)

        Accessible.role: Accessible.ListItem
        Accessible.name: String(modelData.name)
        Accessible.onPressAction: root.chosen(String(modelData.slug))

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: parent.hot ? Style.hoverFillFor(root.foreground, Color.accent, Color.accent) : "transparent"
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: parent.isCurrent ? Model.Glyph.check : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(20)
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.rowPaddingX
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: String(parent.modelData.name)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.cursor = index
          onClicked: root.chosen(String(parent.modelData.slug))
        }
      }
    }
  }
}

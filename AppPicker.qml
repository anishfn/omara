import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Installed-application picker, backed by the shell's own AppLibrary.
// A panel inside the editor card, not a window, so nothing can stack above it.
Item {
  id: root

  required property var editor

  readonly property var service: editor ? editor.service : null
  readonly property var appLibrary: service ? service.appLibrary : null
  readonly property color foreground: editor ? editor.foreground : Color.popups.text
  readonly property color background: editor ? editor.background : Color.popups.background
  readonly property color dim: editor ? editor.dim : Qt.darker(Color.popups.text, 1.5)
  readonly property string fontFamily: editor ? editor.fontFamily : Style.font.family

  property string query: ""
  property int cursor: 0

  readonly property var rows: appLibrary ? appLibrary.sortedEntries(query) : []

  signal chosen(string desktopId)
  signal customRequested()
  signal dismissed()

  function reset() {
    query = ""
    cursor = 0
    if (appLibrary && typeof appLibrary.refreshIcons === "function") appLibrary.refreshIcons()
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
    if (rows.length === 0 || cursor < 0 || cursor >= rows.length) return
    var entry = rows[cursor].entry
    if (!entry || !entry.id) return
    root.chosen(String(entry.id))
  }

  onRowsChanged: cursor = 0

  MouseArea { anchors.fill: parent; onClicked: {} }

  // The popup surface colour carries alpha; force it opaque over the form.
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
        text: "Add application"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Item { width: Math.max(0, layout.width - Style.space(340)); height: 1 }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "Custom command"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.customRequested()
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
      placeholderText: "Search installed applications"
      foreground: root.foreground
      Accessible.name: "Search installed applications"
      onTextChanged: root.query = text

      Keys.onDownPressed: root.move(1)
      Keys.onUpPressed: root.move(-1)
      Keys.onReturnPressed: root.activate()
      Keys.onEnterPressed: root.activate()
      Keys.onEscapePressed: root.dismissed()
    }

    Text {
      width: layout.width
      visible: !root.appLibrary
      wrapMode: Text.Wrap
      text: "The shell's application library is unavailable. Use a custom command instead."
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      width: layout.width
      visible: root.appLibrary && root.rows.length === 0
      wrapMode: Text.Wrap
      text: root.query === "" ? "No applications found." : "Nothing matches \"" + root.query + "\"."
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

        readonly property var entry: modelData.entry
        readonly property bool hot: index === root.cursor || hover.containsMouse

        // list.width, not ListView.view.width: the attached lookup gave a stale one.
        width: list.width
        height: Style.space(40)

        Accessible.role: Accessible.ListItem
        Accessible.name: root.appLibrary ? root.appLibrary.entryName(entry) : ""
        Accessible.onPressAction: root.chosen(String(entry.id))

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: parent.hot ? Style.hoverFillFor(root.foreground, Color.accent, Color.accent) : "transparent"
        }

        Image {
          id: icon
          width: Style.font.iconLarge
          height: Style.font.iconLarge
          fillMode: Image.PreserveAspectFit
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          source: root.appLibrary ? root.appLibrary.iconSource(String(parent.entry.icon || "")) : ""
          asynchronous: true
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          anchors.left: icon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.rowPaddingX
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.appLibrary ? root.appLibrary.entryName(parent.parent.entry) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: root.appLibrary ? root.appLibrary.entrySubtext(parent.parent.entry) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.cursor = index
          onClicked: root.chosen(String(parent.entry.id))
        }
      }
    }
  }
}

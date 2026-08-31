import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One mode in a list. Active state is marked three ways, never colour alone.
Item {
  id: root

  property var mode: null
  property bool isActive: false
  property bool hasCursor: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool reorderable: false

  signal clicked()
  signal editRequested()
  signal moveRequested(int delta)

  readonly property bool hot: hasCursor || mouse.containsMouse
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string name: mode ? String(mode.name || mode.id) : ""
  readonly property string description: mode ? String(mode.description || "") : ""
  readonly property string icon: mode ? String(mode.icon || "") : ""
  readonly property bool disabled: mode ? mode.enabled === false : false

  implicitHeight: layout.implicitHeight + Style.spacing.controlPaddingY * 2
  height: implicitHeight

  Accessible.role: Accessible.ListItem
  Accessible.name: root.name
    + (root.isActive ? ", active, activate again to re-apply" : "")
    + (root.disabled ? ", disabled" : "")
  Accessible.description: root.description
  Accessible.onPressAction: root.clicked()

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.isActive ? Style.selectedFillFor(root.foreground, root.accent, root.accent)
      : root.hot ? Style.hoverFillFor(root.foreground, root.accent, root.accent)
      : "transparent"

    Behavior on color { ColorAnimation { duration: 120 } }
  }

  Row {
    id: layout
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.isActive ? "●" : "○"
      color: root.isActive ? root.foreground : Qt.darker(root.foreground, 2.2)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.icon !== ""
      textFormat: Text.PlainText
      text: root.icon
      color: root.disabled ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: layout.width - layout.spacing * (root.icon !== "" ? 3 : 2)
        - bullet.width - (root.icon !== "" ? iconLabel.width : 0)
        - Math.max(check.width, root.reorderable ? Style.space(40) : 0)
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.name + (root.disabled ? "  (disabled)" : "")
        color: root.disabled ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: root.isActive
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.description !== ""
        textFormat: Text.PlainText
        text: root.description
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  Text {
    id: bullet
    visible: false
    text: "●"
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    id: iconLabel
    visible: false
    text: root.icon
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon
  }

  Text {
    id: check
    anchors.right: reorder.visible ? reorder.left : parent.right
    anchors.rightMargin: Style.spacing.rowPaddingX
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.isActive ? (root.hot ? Model.Glyph.refresh : Model.Glyph.check) : ""
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon
  }

  Row {
    id: reorder
    visible: root.reorderable && root.hot
    anchors.right: parent.right
    anchors.rightMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    spacing: 0

    PanelActionButton {
      iconText: Model.Glyph.chevronUp
      tooltipText: "Move up"
      fontSize: Style.font.caption
      size: Style.space(18)
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.moveRequested(-1)
    }

    PanelActionButton {
      iconText: Model.Glyph.chevronDown
      tooltipText: "Move down"
      fontSize: Style.font.caption
      size: Style.space(18)
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.moveRequested(1)
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(event) {
      if (event.button === Qt.RightButton) root.editRequested()
      else root.clicked()
    }
  }
}

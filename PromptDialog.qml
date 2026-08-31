import QtQuick
import qs.Commons
import qs.Ui

// A modal question with more than two answers, which is the one thing the
// kit's ConfirmDialog cannot do. Choices are labels; `chosen` reports the index.
Item {
  id: root

  property bool opened: false
  property string message: ""
  property var choices: []
  property int destructiveIndex: -1
  property int selected: 0
  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property string fontFamily: Style.font.family

  signal chosen(int index)
  signal dismissed()

  visible: opened

  function open(text, options, destructive) {
    root.message = String(text || "")
    root.choices = options || []
    root.destructiveIndex = destructive === undefined ? -1 : destructive
    root.selected = 0
    root.opened = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function move(delta) {
    if (choices.length === 0) return
    selected = (selected + delta + choices.length) % choices.length
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.72)
    MouseArea { anchors.fill: parent; onClicked: root.dismissed() }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: root.opened

    Keys.onLeftPressed: root.move(-1)
    Keys.onRightPressed: root.move(1)
    Keys.onEscapePressed: root.dismissed()
    Keys.onReturnPressed: root.chosen(root.selected)
    Keys.onEnterPressed: root.chosen(root.selected)

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(48), Style.space(420))
      height: card.implicitHeight + Style.spacing.panelPadding * 2
      radius: Style.cornerRadius
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
      border.width: Math.max(1, Style.normalBorderWidth)
      border.color: Color.popups.border

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: card
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.space(16)

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.message
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Row {
          anchors.right: parent.right
          spacing: Style.space(6)

          Repeater {
            model: root.choices

            Button {
              required property var modelData
              required property int index

              text: String(modelData)
              bordered: index === root.selected
              hasCursor: index === root.selected
              foreground: index === root.destructiveIndex ? Color.urgent : root.foreground
              fontFamily: root.fontFamily
              Accessible.name: String(modelData)
              onClicked: root.chosen(index)
              onHovered: function(on) { if (on) root.selected = index }
            }
          }
        }
      }
    }
  }
}

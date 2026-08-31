import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Omara mark, drawn rather than loaded, so it takes the bar's own colour
// and stays sharp at 16px. A sphere and a play triangle, the same silhouette
// as the logo, reduced to one tone and a gap so both shapes read when small.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property real sphere: iconSize * 0.72
  readonly property real gap: iconSize * 0.12
  readonly property real wing: iconSize * 0.42
  readonly property real wingHeight: iconSize * 0.84
  readonly property real wingLeft: sphere + gap

  implicitWidth: sphere + gap + wing
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.sphere
    height: root.sphere
    radius: root.sphere / 2
    color: root.color
    antialiasing: true
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.wingLeft
      startY: (root.height - root.wingHeight) / 2
      PathLine { x: root.width; y: root.height / 2 }
      PathLine { x: root.wingLeft; y: (root.height + root.wingHeight) / 2 }
      PathLine { x: root.wingLeft; y: (root.height - root.wingHeight) / 2 }
    }
  }
}

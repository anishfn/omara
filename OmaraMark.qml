import QtQuick
import qs.Commons

// The Omara mark: a board with a layout in it, which is what a mode is and
// what the editor draws. Drawn rather than loaded, so it takes the bar's own
// colour and stays sharp at the size the bar asks for.
//
// The panes are deliberately uneven — one tall, two stacked beside it. Split
// a board down the middle and you have drawn a table; split it the way a
// tiling window manager does and you have drawn a layout. That asymmetry is
// the whole difference between this and a stock split-view icon.
//
// Three rectangles and a border, no paths. Everything here has to survive
// being resolved at about eleven pixels — the ink height of the glyphs either
// side of it — and at that size a shape is only as good as the number of
// parts it has. A lit pane was tried and dropped: a fill inside the board
// merges into the board's own edge before it ever reads as a pane.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  // The mark is 100 units wide and 72 tall. `u` is picked so the height comes
  // out at about 0.69 of the bar's icon size: a glyph does not fill its em box
  // either, and measured against the tray, those icons put roughly eleven
  // pixels of ink in a sixteen pixel canvas.
  readonly property real u: iconSize * 0.0096

  readonly property real artWidth: 100 * u
  readonly property real artHeight: 72 * u

  // Never thinner than a pixel: a hairline beside the solid glyphs of the
  // rest of the bar reads as a rendering fault rather than as a thin stroke.
  readonly property real stroke: Math.max(1, 12 * u)

  implicitWidth: artWidth
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  // The board.
  Rectangle {
    id: board
    anchors.centerIn: parent
    width: root.artWidth
    height: root.artHeight
    radius: 14 * root.u
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
    antialiasing: true

    // The split, off centre, leaving a wide pane and a narrow column.
    Rectangle {
      id: column
      x: 50 * root.u
      y: root.stroke
      width: root.stroke
      height: board.height - root.stroke * 2
      color: root.color
      antialiasing: true
    }

    // The narrow column, halved.
    Rectangle {
      x: column.x + column.width
      y: (board.height - root.stroke) / 2
      width: board.width - root.stroke - x
      height: root.stroke
      color: root.color
      antialiasing: true
    }
  }
}

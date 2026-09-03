import QtQuick
import qs.Commons

// The Omara mark: a board with two panes, which is what a mode is and what
// the editor draws. Drawn rather than loaded, so it takes the bar's own
// colour and stays sharp at the size the bar asks for.
//
// Two rectangles and no paths. Everything here has to survive being resolved
// at about eleven pixels — the ink height of the glyphs either side of it —
// and at that size a shape is only as good as the number of parts it has.
// A frame, a divider and the gaps between them is already four things inside
// eleven pixels; a lit pane inside one of them would be a fifth, and its fill
// merges into the frame's own edge before it ever reads as a pane.
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
  }

  // The split. Centred on the board's interior rather than on its edges, so
  // the two panes come out the same width whatever the stroke rounded to.
  Rectangle {
    anchors.centerIn: board
    width: root.stroke
    height: board.height - root.stroke * 2
    color: root.color
    antialiasing: true
  }
}

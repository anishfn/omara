import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Omara mark, drawn rather than loaded, so it takes the bar's own colour
// and stays sharp at 16px. Two cards: the one you are in, and the one behind
// it you can switch to.
//
// The back card is an open stroke, not a rectangle with the front card laid
// over it. A mark on a bar has no background of its own to knock a gap out
// with — the wallpaper is behind it — so the gap is in the path itself: the
// stroke stops short of the front card on both ends and the two shapes read
// as separate at any size and on any backdrop.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  // The canvas the bar allots, and the ink drawn inside it. A glyph does not
  // fill its em box either: measured against the tray beside it, those icons
  // put about eleven pixels of ink in a sixteen pixel canvas, and a mark drawn
  // edge to edge sits among them looking a size too big.
  readonly property real artSize: iconSize * 0.7

  // Everything below is in a 100-unit square, scaled to artSize on the way
  // out, so the proportions hold whatever the bar's icon size is.
  readonly property real u: artSize / 100

  // Never thinner than a pixel: a hairline outline beside the solid glyphs of
  // the rest of the bar reads as a rendering fault.
  readonly property real stroke: Math.max(1, 14 * u)

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  // The ink is centred in the canvas rather than anchored to its corner, so
  // the mark sits on the same optical line as the glyphs either side of it.
  readonly property real inset: (iconSize - artSize) / 2

  // The card in front, the mode you are in.
  Rectangle {
    x: root.inset + 3 * root.u
    y: root.inset + 42 * root.u
    width: 66 * root.u
    height: 54 * root.u
    radius: 9 * root.u
    color: root.color
    antialiasing: true
  }

  // The card behind, drawn only where the front one does not cover it, and
  // stopping 6 units short at each end so the two never touch.
  Shape {
    x: root.inset
    y: root.inset
    width: root.artSize
    height: root.artSize
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.color
      strokeWidth: root.stroke
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin

      // Up the left side, over the top, and down the right to the corner.
      // It stops there: the rest of that card is behind the one in front.
      // Both ends stop 8 units clear of the front card. Half of that is the
      // stroke's own round cap, so what is left is the gap you actually see —
      // and it has to survive being scaled down to 16 pixels.
      startX: 26 * root.u
      startY: 28 * root.u
      PathLine { x: 26 * root.u; y: 17 * root.u }
      PathArc {
        x: 35 * root.u; y: 8 * root.u
        radiusX: 9 * root.u; radiusY: 9 * root.u
        direction: PathArc.Clockwise
      }
      PathLine { x: 83 * root.u; y: 8 * root.u }
      PathArc {
        x: 92 * root.u; y: 17 * root.u
        radiusX: 9 * root.u; radiusY: 9 * root.u
        direction: PathArc.Clockwise
      }
      PathLine { x: 92 * root.u; y: 51 * root.u }
      PathArc {
        x: 83 * root.u; y: 60 * root.u
        radiusX: 9 * root.u; radiusY: 9 * root.u
        direction: PathArc.Clockwise
      }
    }
  }
}

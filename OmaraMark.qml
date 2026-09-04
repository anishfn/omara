import QtQuick
import qs.Commons

// The Workspace Modes mark: the shape a dwindle layout makes — one pane down the left,
// two stacked beside it. Drawn rather than loaded, so it takes the bar's own
// colour and stays sharp at the size the bar asks for.
//
// The geometry is taken off the layout icon already in the bar, so this reads
// as one of the set rather than as a guest: a nine by nine grid, four units
// for the left pane, four for the right column, and one unit of gap between
// them and between the two blocks on the right.
//
// That gap is a single device pixel at the default bar size, so every edge
// here is rounded to a whole one. Centred by anchors the art landed on a half
// pixel, and half a pixel of antialiasing either side of a one pixel gap
// closes it: the three blocks resolved into one grey smudge.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property real unit: Math.max(1, Math.round(iconSize / 16))
  readonly property real block: unit * 4
  readonly property real stride: unit * 5
  readonly property real artSize: unit * 9
  // Floor, not round: with a nine unit mark in a sixteen unit canvas the
  // difference is 3.5, and rounding it up drops the mark a pixel below the
  // glyphs either side of it.
  readonly property real offsetY: Math.floor((root.height - root.artSize) / 2)

  implicitWidth: artSize
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  // The pane down the left.
  Rectangle {
    x: 0
    y: root.offsetY
    width: root.block
    height: root.artSize
    color: root.color
  }

  // The column beside it, halved.
  Rectangle {
    x: root.stride
    y: root.offsetY
    width: root.block
    height: root.block
    color: root.color
  }

  Rectangle {
    x: root.stride
    y: root.offsetY + root.stride
    width: root.block
    height: root.block
    color: root.color
  }
}

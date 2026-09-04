import QtQuick
import qs.Ui

// A text field that knows what the model currently says, so it can be trusted
// in a delegate that gets re-pointed at something else underneath it.
//
// Two things a plain TextField gets wrong here. First, typing into one breaks
// the binding on `text`, and nothing puts it back: the pane Repeaters are
// modelled on a *count* so their delegates survive a change to the tree, and a
// field whose binding had been broken went on showing — and on committing —
// the text it was given for a pane it is no longer drawing. Second, Escape is
// not consumed by a text field, so it walked up to the overlay and closed the
// whole editor rather than abandoning the edit in front of you.
//
// `committed` is the value the model holds. Set it to the same expression the
// old `text:` binding used, and this re-syncs whenever it changes, refuses to
// write back a value it has not been edited into, and takes Escape.
TextField {
  id: field

  // What the draft says right now.
  property string committed: ""

  // Emitted only when the text really differs from what the model holds, so
  // merely visiting a field and clicking away no longer marks a mode unsaved.
  signal commit(string value)

  text: committed

  // Re-point, rather than leave a broken binding showing the last pane's text.
  // A value the user has just typed and committed arrives here unchanged, so
  // this cannot fight with typing.
  onCommittedChanged: if (text !== committed) text = committed

  onEditingFinished: if (text !== committed) field.commit(text)

  Keys.onEscapePressed: function(event) {
    text = committed
    event.accepted = true
  }
}

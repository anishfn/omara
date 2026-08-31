import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Asks what to do with the windows already on screen before a mode switch.
// Its own overlay window so it can appear without the editor being open.
Item {
  id: root

  property var service: null
  property bool opened: false
  property string message: ""

  signal answered(string mode)   // close | keep
  signal cancelled()

  function openWith(text) {
    root.message = String(text || "")
    root.opened = true
    Qt.callLater(function() { prompt.open(root.message, ["Close them", "Keep them", "Cancel"], 0) })
  }

  function close() {
    root.opened = false
    prompt.close()
  }

  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omara-switch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    PromptDialog {
      id: prompt
      anchors.fill: parent
      foreground: Color.popups.text
      background: Color.popups.background
      fontFamily: Style.font.family
      onChosen: function(index) {
        if (index === 0) root.answered("close")
        else if (index === 1) root.answered("keep")
        else root.cancelled()
      }
      onDismissed: root.cancelled()
    }
  }
}

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
    id: switchWindow
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "wsmodes-switch"
    WlrLayershell.layer: WlrLayer.Overlay

    // Primed then released, for the reason the editor is: a surface holding
    // the keyboard exclusively is delivered typing meant for whatever you are
    // actually looking at, and this one asks a question with a destructive
    // answer on it.
    property bool focusPrimed: false
    WlrLayershell.keyboardFocus: visible
      ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    onVisibleChanged: {
      switchWindow.focusPrimed = false
      if (visible) focusPrime.restart()
      else focusPrime.stop()
    }

    Timer {
      id: focusPrime
      interval: 75
      onTriggered: if (switchWindow.visible) switchWindow.focusPrimed = true
    }

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

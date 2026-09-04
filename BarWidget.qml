import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button and switcher popup. Holds no state; reads the service.
BarWidget {
  id: root
  moduleName: "io.github.anishfn.workspace-modes"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null

  readonly property var modes: service ? service.modes : []
  readonly property var activeMode: service ? service.activeMode : null
  readonly property bool activating: service ? service.activating === true : false
  readonly property bool showIcon: setting("showIcon", true) === true
  readonly property bool showName: setting("showName", true) === true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string modeIcon: activeMode && activeMode.icon ? String(activeMode.icon) : ""
  readonly property string modeName: activeMode ? String(activeMode.name) : "No mode"

  // The mark is the Workspace Modes logo until a mode brings its own icon, so the bar
  // says which mode you are in before it says whose plugin this is.
  readonly property bool showLogo: root.showIcon && root.modeIcon === ""
  readonly property string glyphText: root.showIcon && root.modeIcon !== "" ? root.modeIcon : ""
  readonly property string labelText:
    root.showName || (!root.showIcon && !root.showName) ? root.modeName : ""

  // ------------------------------------------------- shell summon interface

  // shell.qml's summon routing needs exactly these three names.
  readonly property bool opened: panel.open
  function open() { cursorIndex = indexOfActive(); cursorActive = false; panel.open = true }
  function close() { panel.open = false }
  function toggle() { opened ? close() : open() }

  // ------------------------------------------------------ keyboard cursor

  property int cursorIndex: 0
  property bool cursorActive: false

  // The three actions are always on screen now, including on an empty popup,
  // so the cursor can no longer land on a row that is not being drawn.
  readonly property int actionCount: 3
  readonly property int rowCount: modes.length + actionCount

  function indexOfActive() {
    for (var i = 0; i < modes.length; i++) if (modes[i].id === (activeMode ? activeMode.id : "")) return i
    return 0
  }

  function moveCursor(delta) {
    if (rowCount === 0) return
    if (!cursorActive) { cursorActive = true; return }
    var next = cursorIndex + delta
    if (next < 0) next = rowCount - 1
    if (next >= rowCount) next = 0
    cursorIndex = next
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    if (cursorIndex < modes.length) { chooseMode(modes[cursorIndex]); return }
    var action = cursorIndex - modes.length
    if (action === 0) newMode()
    else if (action === 1) manageModes()
    else disableMode()
  }

  // --------------------------------------------------------------- actions

  function chooseMode(mode) {
    if (!service || !mode || service.activating) return
    close()
    service.activateMode(mode.id)
  }

  function newMode() {
    if (!service) return
    close()
    service.requestEditor("new")
  }

  function manageModes() {
    if (!service) return
    close()
    service.requestEditor("")
  }

  function disableMode() {
    if (!service) return
    close()
    service.deactivateMode()
  }

  readonly property real logoSize: Style.bar.iconCanvas

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { cursorIndex = indexOfActive(); cursorActive = false }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontFamily: root.fontFamily
    tooltipText: root.activeMode
      ? (root.activeMode.description || root.activeMode.name)
      : "No mode active"
    // Dimmed while an activation is in flight, so a mode that opens four
    // apps does not look like a click that did nothing.
    dimmed: !root.activeMode || root.activating
    onPressed: function(b) {
      if (b === Qt.RightButton) root.manageModes()
      else root.toggle()
    }

    // The kit's label is centred and text-only, so the logo needs a row of
    // our own. Everything else about the button still comes from the kit.
    labelVisible: false
    hasVisualContent: true
    fixedWidth: vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(6)

      ModesMark {
        visible: root.showLogo
        anchors.verticalCenter: parent.verticalCenter
        iconSize: root.logoSize
        color: root.foreground
      }

      Text {
        visible: root.glyphText !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.glyphText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        renderType: Text.NativeRendering
      }

      Text {
        visible: root.labelText !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.labelText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function") root.bar.switchPanelFrom(root, direction)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(6)

        // No section header: this popup is summoned from the mode widget and
        // its rows are modes. A line that says "Mode" over them is a row spent
        // on something the reader already knows.
        Text {
          width: parent.width
          visible: root.modes.length === 0
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "No modes yet. A mode is a way your desktop is set up — "
            + "what opens, where, and how it behaves."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: root.modes

          ModeRow {
            required property var modelData
            required property int index

            width: column.width
            mode: modelData
            opacity: root.activating ? 0.5 : 1
            isActive: root.activeMode !== null && root.activeMode.id === modelData.id
            hasCursor: root.cursorActive && root.cursorIndex === index
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.chooseMode(modelData)
            onEditRequested: {
              root.close()
              if (root.service) root.service.requestEditor(modelData.id)
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
          visible: root.modes.length > 0
        }

        // One row, not three. These are what you do *to* modes rather than
        // more modes, and stacking them full width made the popup twice as
        // tall as the list it was there to show.
        Row {
          width: parent.width
          spacing: Style.space(4)

          Button {
            iconText: Model.Glyph.add
            text: "New"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            tooltipText: "Start a mode from nothing"
            hasCursor: root.cursorActive && root.cursorIndex === root.modes.length
            onClicked: root.newMode()
          }

          Button {
            iconText: Model.Glyph.settings
            text: "Manage"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            tooltipText: "Open the editor"
            hasCursor: root.cursorActive && root.cursorIndex === root.modes.length + 1
            onClicked: root.manageModes()
          }

          Button {
            iconText: Model.Glyph.power
            bordered: true
            enabled: root.activeMode !== null
            foreground: root.activeMode ? root.foreground : root.dim
            fontFamily: root.fontFamily
            tooltipText: "Turn the active mode off"
            Accessible.name: "Turn the active mode off"
            hasCursor: root.cursorActive && root.cursorIndex === root.modes.length + 2
            onClicked: root.disableMode()
          }
        }
      }
    }
  }
}

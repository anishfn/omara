import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Everything about a mode that is not its workspaces: what it is called, what
// it does to the environment, and the commands and triggers behind Advanced.
// The workspaces themselves are WorkspaceCanvas, which is the editor's main
// view rather than a section of this form.
//
// Text fields commit on editingFinished so the draft does not change (and
// re-drive the `text` binding) while you are typing.
Column {
  id: form

  required property var editor

  readonly property var draft: editor ? editor.draft : null
  readonly property var service: editor ? editor.service : null
  readonly property color foreground: editor ? editor.foreground : Color.foreground
  readonly property color dim: editor ? editor.dim : Qt.darker(Color.foreground, 1.5)
  readonly property string fontFamily: editor ? editor.fontFamily : Style.font.family

  property bool showAdvanced: false

  // Tab from the panel lands here rather than on the header buttons, so the
  // keyboard path into a mode starts at its name.
  function focusFirstField() { nameField.forceActiveFocus() }

  spacing: Style.space(12)

  // ------------------------------------------------------------- identity

  PanelSectionHeader { width: form.width; text: "Mode"; foreground: form.foreground; fontFamily: form.fontFamily }

  Row {
    width: form.width
    spacing: Style.space(8)

    TextField {
      id: nameField
      width: form.width - iconField.width - parent.spacing
      text: form.draft ? form.draft.name : ""
      placeholderText: "Name"
      foreground: form.foreground
      Accessible.name: "Mode name"
      onEditingFinished: form.editor.setDraft("name", text)
    }

    Button {
      id: iconField
      width: Style.space(70)
      height: Style.spacing.controlHeight + Style.spacing.inputPaddingY
      bordered: true
      text: form.draft && form.draft.icon ? form.draft.icon : "icon"
      fontSize: form.draft && form.draft.icon ? Style.font.icon : Style.font.bodySmall
      foreground: form.draft && form.draft.icon ? form.foreground : form.dim
      fontFamily: form.fontFamily
      tooltipText: "Choose an icon"
      focusable: true
      Accessible.name: "Choose a mode icon"
      onClicked: form.editor.openIconPicker()
    }
  }

  TextField {
    width: form.width
    text: form.draft ? form.draft.description : ""
    placeholderText: "Description"
    foreground: form.foreground
    Accessible.name: "Mode description"
    onEditingFinished: form.editor.setDraft("description", text)
  }

  Text {
    width: form.width
    textFormat: Text.PlainText
    text: "id: " + (form.draft ? form.draft.id : "") + "  ·  renaming keeps the id, so shortcuts keep working"
    color: form.dim
    font.family: form.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  PanelSeparator { width: form.width; foreground: form.foreground }

  // ---------------------------------------------------------- environment

  PanelSectionHeader { width: form.width; text: "Environment"; foreground: form.foreground; fontFamily: form.fontFamily }

  Dropdown {
    width: form.width
    label: "Notifications"
    foreground: form.foreground
    fontFamily: form.fontFamily
    options: form.editor ? form.editor.dndOptions : []
    value: {
      if (!form.draft) return "unchanged"
      var dnd = form.draft.notifications.dnd
      return dnd === null || dnd === undefined ? "unchanged" : (dnd ? "on" : "off")
    }
    onChanged: function(v) { form.editor.setDraft("notifications.dnd", v === "unchanged" ? null : v === "on") }
  }

  Dropdown {
    width: form.width
    label: "Audio output"
    foreground: form.foreground
    fontFamily: form.fontFamily
    options: form.editor ? form.editor.audioOptions : []
    value: form.draft && form.draft.audio.output ? String(form.draft.audio.output) : ""
    onChanged: function(v) { form.editor.setDraft("audio.output", v === "" ? null : v) }
  }

  Row {
    width: form.width
    spacing: Style.space(6)

    TextField {
      width: form.width - browseButton.width - parent.spacing
      text: form.draft && form.draft.appearance.wallpaper ? String(form.draft.appearance.wallpaper) : ""
      placeholderText: "Wallpaper path, blank leaves it alone"
      foreground: form.foreground
      Accessible.name: "Wallpaper path"
      onEditingFinished: form.editor.setDraft("appearance.wallpaper", text)
    }

    Button {
      id: browseButton
      anchors.verticalCenter: parent.verticalCenter
      text: "Browse"
      foreground: form.foreground
      fontFamily: form.fontFamily
      onClicked: form.editor.browseWallpaper()
    }
  }

  Button {
    width: form.width
    height: Style.spacing.controlHeight + Style.spacing.inputPaddingY
    leftAlign: true
    bordered: true
    text: form.draft && form.draft.appearance.theme
      ? "Theme:  " + Model.prettyThemeName(form.draft.appearance.theme)
      : "Theme:  leave unchanged"
    foreground: form.draft && form.draft.appearance.theme ? form.foreground : form.dim
    fontFamily: form.fontFamily
    tooltipText: "Choose a theme"
    focusable: true
    Accessible.name: "Choose a theme"
    onClicked: form.editor.openThemePicker()
  }

  PanelSeparator { width: form.width; foreground: form.foreground }

  // ------------------------------------------------------------- advanced

  Button {
    width: form.width
    leftAlign: true
    focusable: true
    iconText: form.showAdvanced ? Model.Glyph.chevronDown : Model.Glyph.chevronRight
    text: "Advanced: commands and automatic triggers"
    foreground: form.foreground
    fontFamily: form.fontFamily
    Accessible.name: "Toggle advanced settings"
    onClicked: form.showAdvanced = !form.showAdvanced
  }

  Column {
    width: form.width
    spacing: Style.space(10)
    visible: form.showAdvanced

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      text: "Commands run through your shell, as you, every time this mode is switched on or off. Treat them the way you treat your own dotfiles."
      color: form.dim
      font.family: form.fontFamily
      font.pixelSize: Style.font.caption
    }

    PanelSectionHeader { width: parent.width; text: "On activate"; foreground: form.foreground; fontFamily: form.fontFamily }

    Repeater {
      model: form.draft ? form.draft.commands.onActivate : []

      Row {
        required property var modelData
        required property int index
        width: form.width
        spacing: Style.space(6)

        TextField {
          width: form.width - Style.space(46)
          text: modelData
          placeholderText: "Shell command"
          foreground: form.foreground
          Accessible.name: "Activation command"
          onEditingFinished: form.editor.setDraftListItem("commands.onActivate", index, text)
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.Glyph.close
          tooltipText: "Remove this command"
          foreground: form.foreground
          fontFamily: form.fontFamily
          onClicked: form.editor.removeDraftListItem("commands.onActivate", index)
        }
      }
    }

    Button {
      width: parent.width
      leftAlign: true
      focusable: true
      iconText: Model.Glyph.add
      text: "Add activation command"
      foreground: form.foreground
      fontFamily: form.fontFamily
      onClicked: form.editor.pushDraftList("commands.onActivate", "")
    }

    PanelSectionHeader { width: parent.width; text: "On deactivate"; foreground: form.foreground; fontFamily: form.fontFamily }

    Repeater {
      model: form.draft ? form.draft.commands.onDeactivate : []

      Row {
        required property var modelData
        required property int index
        width: form.width
        spacing: Style.space(6)

        TextField {
          width: form.width - Style.space(46)
          text: modelData
          placeholderText: "Shell command"
          foreground: form.foreground
          Accessible.name: "Deactivation command"
          onEditingFinished: form.editor.setDraftListItem("commands.onDeactivate", index, text)
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.Glyph.close
          tooltipText: "Remove this command"
          foreground: form.foreground
          fontFamily: form.fontFamily
          onClicked: form.editor.removeDraftListItem("commands.onDeactivate", index)
        }
      }
    }

    Button {
      width: parent.width
      leftAlign: true
      iconText: Model.Glyph.add
      text: "Add deactivation command"
      foreground: form.foreground
      fontFamily: form.fontFamily
      onClicked: form.editor.pushDraftList("commands.onDeactivate", "")
    }

    PanelSectionHeader { width: parent.width; text: "Automatic triggers"; foreground: form.foreground; fontFamily: form.fontFamily }

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      visible: form.service && form.service.config.behavior.triggersEnabled !== true
      text: "Triggers are switched off globally. Turn them on under Settings for any of these to fire."
      color: Color.urgent
      font.family: form.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: form.draft ? form.draft.triggers : []

      Row {
        required property var modelData
        required property int index
        width: form.width
        spacing: Style.space(6)

        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: modelData.enabled !== false
          foreground: form.foreground
          Accessible.name: "Trigger enabled"
          onToggled: form.editor.setDraftListItem("triggers", index, {
            type: modelData.type, value: modelData.value,
            enabled: modelData.enabled === false, behavior: modelData.behavior
          })
        }

        TextField {
          width: form.width - Style.space(210)
          text: modelData.value
          placeholderText: "Window class, e.g. steam"
          foreground: form.foreground
          Accessible.name: "Trigger window class"
          onEditingFinished: form.editor.setDraftListItem("triggers", index, {
            type: modelData.type, value: text,
            enabled: modelData.enabled !== false, behavior: modelData.behavior
          })
        }

        Dropdown {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(112)
          showLabel: false
          foreground: form.foreground
          fontFamily: form.fontFamily
          options: [
            { value: "", label: "Default" },
            { value: "ask", label: "Ask" },
            { value: "auto", label: "Switch" }
          ]
          value: modelData.behavior || ""
          onChanged: function(v) {
            form.editor.setDraftListItem("triggers", index, {
              type: modelData.type, value: modelData.value,
              enabled: modelData.enabled !== false, behavior: v
            })
          }
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.Glyph.close
          tooltipText: "Remove this trigger"
          foreground: form.foreground
          fontFamily: form.fontFamily
          onClicked: form.editor.removeDraftListItem("triggers", index)
        }
      }
    }

    Button {
      width: parent.width
      leftAlign: true
      iconText: Model.Glyph.add
      text: "Add trigger"
      foreground: form.foreground
      fontFamily: form.fontFamily
      onClicked: form.editor.pushDraftList("triggers", { type: "application", value: "", enabled: true, behavior: "" })
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import qs.Commons
import "Model.js" as Model

// Single source of truth: config, runtime snapshot, activation, triggers, IPC.
// The shell instantiates a service plugin once, which is what makes it single.
Item {
  id: service

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/omara.json"
  readonly property string statePath: home + "/.local/state/omarchy/omara-state.json"

  // ------------------------------------------------------------------ state

  property var config: Model.defaultConfig()
  property bool configLoaded: false
  property string lastWrittenText: ""

  property bool activating: false
  property double lastActivationAt: -1e12
  property var previousState: ({})

  property var activityLog: []
  property int activityLogLimit: 60

  readonly property var modes: config && Array.isArray(config.modes) ? config.modes : []
  readonly property string activeModeId: config && config.activeMode ? String(config.activeMode) : ""
  readonly property var activeMode: Model.findMode(config, activeModeId)

  signal modesUpdated()
  signal activationFinished(string modeId, int warnings)
  signal logged()

  // ---------------------------------------------------------------- logging

  function log(level, message) {
    var entry = { level: String(level), message: String(message), at: Date.now() }
    var next = [entry].concat(activityLog)
    if (next.length > activityLogLimit) next = next.slice(0, activityLogLimit)
    activityLog = next
    if (level === "warn") console.warn("[omara]", message)
    else console.log("[omara]", message)
    service.logged()
  }

  function clearLog() {
    activityLog = []
    service.logged()
  }

  // ------------------------------------------------------------ persistence

  function applyConfig(next, reason) {
    var normalized = Model.normalizeConfig(next)
    service.config = normalized.config
    for (var i = 0; i < normalized.warnings.length; i++) log("warn", normalized.warnings[i])
    save()
    service.modesUpdated()
    if (reason) log("info", reason)
  }

  function save() {
    if (!configLoaded) return
    var text = Model.serializeConfig(service.config)
    if (text === lastWrittenText) return
    lastWrittenText = text
    configFile.setText(text)
  }

  function loadConfig(raw) {
    var parsed = Model.parseConfig(raw)
    service.config = parsed.config
    for (var i = 0; i < parsed.warnings.length; i++) log("warn", parsed.warnings[i])
    if (parsed.recovered) service.backupBrokenConfig()
    service.configLoaded = true
    service.modesUpdated()
  }

  function backupBrokenConfig() {
    var backup = service.configPath + ".corrupt"
    log("warn", "Copied the unreadable omara.json to " + backup + " before starting from defaults")
    Quickshell.execDetached(["bash", "-lc", 'cp -f -- "$1" "$2"', "bash", service.configPath, backup])
    Quickshell.execDetached([
      "omarchy-notification-send", "--app-name", "Omara", "-u", "normal",
      "Omara", "omara.json could not be read. A copy was saved as omara.json.corrupt."
    ])
  }

  FileView {
    id: configFile
    path: service.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var text = this.text()
      if (service.configLoaded && text === service.lastWrittenText) return
      service.lastWrittenText = text
      service.configFileSeen = true
      service.loadConfig(text)
    }
    onLoadFailed: if (!service.configLoaded) service.loadConfig("")
  }

  property bool configFileSeen: false

  // A file watcher dies when the file is replaced by rename; this heals it.
  Timer {
    id: reconcileTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: configFile.reload()
  }

  FileView {
    id: stateFile
    path: service.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadState(this.text())
    onLoadFailed: service.previousState = ({})
  }

  function loadState(raw) {
    try {
      var parsed = JSON.parse(String(raw || "").trim() || "{}")
      service.previousState = Model.isPlainObject(parsed) ? parsed : ({})
    } catch (e) {
      service.previousState = ({})
    }
  }

  function saveState() {
    stateFile.setText(JSON.stringify(service.previousState, null, 2) + "\n")
  }

  // ----------------------------------------------------------- environment

  readonly property var appLibrary: shell && shell.appLibrary ? shell.appLibrary : null

  readonly property var notificationsService: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("omarchy.notifications") : null

  readonly property var sinkNodes: {
    var out = []
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) out.push(n)
    }
    return out
  }

  function currentDnd() {
    return notificationsService ? notificationsService.doNotDisturb === true : null
  }

  function currentAudioOutput() {
    var sink = Pipewire.defaultAudioSink
    return sink && sink.name ? String(sink.name) : ""
  }

  function findSink(name) {
    var wanted = String(name || "")
    if (wanted === "") return null
    var list = sinkNodes
    for (var i = 0; i < list.length; i++) if (String(list[i].name) === wanted) return list[i]
    for (var d = 0; d < list.length; d++) {
      var desc = list[d].description ? String(list[d].description) : ""
      if (desc !== "" && desc === wanted) return list[d]
    }
    return null
  }

  // ------------------------------------------------------------- executing

  function setDnd(value) {
    var on = value === true
    if (notificationsService && typeof notificationsService.setDoNotDisturb === "function") {
      notificationsService.setDoNotDisturb(on)
      Quickshell.execDetached(["omarchy-shell", "-q", "omarchy.indicators", "refresh"])
      return { ok: true, detail: on ? "Do Not Disturb on" : "Do Not Disturb off" }
    }
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", on ? "on" : "off"])
    return { ok: true, detail: on ? "Do Not Disturb on" : "Do Not Disturb off" }
  }

  function setAudioOutput(name) {
    var node = findSink(name)
    if (!node) return { ok: false, detail: "Audio output \"" + name + "\" is not available; kept the current output" }
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
    return { ok: true, detail: "Audio output → " + String(node.description || node.name) }
  }

  function setWallpaper(path) {
    var p = String(path || "")
    if (p === "") return { ok: false, detail: "No wallpaper set" }
    Quickshell.execDetached(["omarchy-theme-bg-set", p])
    return { ok: true, detail: "Wallpaper → " + p }
  }

  function setTheme(name) {
    var n = String(name || "")
    if (n === "") return { ok: false, detail: "No theme set" }
    Quickshell.execDetached(["omarchy-theme-set", n])
    return { ok: true, detail: "Theme → " + n }
  }

  function focusWorkspace(target) {
    var id = String(target)
    var command = Hyprland.usingLua
      ? "hl.dsp.focus({ workspace = \"" + id.replace(/"/g, "") + "\" })"
      : "workspace " + id
    Hyprland.dispatch(command)
    return { ok: true, detail: "Workspace → " + id }
  }

  function desktopEntry(desktopId) {
    var id = String(desktopId || "")
    if (id === "") return null
    var entries = DesktopEntries.applications ? DesktopEntries.applications.values : []
    for (var i = 0; i < entries.length; i++)
      if (entries[i] && String(entries[i].id) === id) return entries[i]
    return null
  }

  function desktopLaunchCommand(desktopId) {
    return "uwsm-app -- gtk-launch " + Util.shellQuote(String(desktopId) + ".desktop")
  }

  // Placement without focus theft, so a mode can lay out several workspaces.
  function launchOnWorkspace(workspace, command) {
    var rule = Model.hyprlandExecRule(workspace, command)
    Hyprland.dispatch(Hyprland.usingLua
      ? "hl.dsp.exec_cmd(" + Model.luaQuote(rule) + ")"
      : "exec " + rule)
  }

  function launchDesktopEntry(desktopId, workspace) {
    var entry = desktopEntry(desktopId)
    if (!entry)
      return { ok: false, detail: "\"" + desktopId + "\" is not installed; skipped" }
    var name = String(entry.name || desktopId)
    var where = workspace === null || workspace === undefined ? "" : " on workspace " + workspace

    if (where !== "") {
      launchOnWorkspace(workspace, desktopLaunchCommand(desktopId))
      return { ok: true, detail: "Launched " + name + where }
    }
    if (appLibrary && typeof appLibrary.launch === "function") {
      appLibrary.launch(desktopId, name)
      return { ok: true, detail: "Launched " + name }
    }
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash",
      "uwsm-app", "--", "gtk-launch", desktopId + ".desktop"])
    return { ok: true, detail: "Launched " + name }
  }

  function launchApplication(command, workspace) {
    var parsed = Model.parseArgv(command)
    if (parsed.argv.length === 0)
      return { ok: false, detail: "Empty application command" }
    if (parsed.unterminated)
      return { ok: false, detail: "Unbalanced quote in \"" + command + "\"" }

    if (workspace !== null && workspace !== undefined) {
      var quoted = []
      for (var i = 0; i < parsed.argv.length; i++) quoted.push(Util.shellQuote(parsed.argv[i]))
      launchOnWorkspace(workspace, quoted.join(" "))
      return { ok: true, detail: "Launched " + parsed.argv[0] + " on workspace " + workspace }
    }

    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(parsed.argv))
    return { ok: true, detail: "Launched " + parsed.argv[0] }
  }

  function runCommand(command) {
    var c = String(command || "").trim()
    if (c === "") return { ok: false, detail: "Empty command" }
    Quickshell.execDetached(["bash", "-lc", c])
    return { ok: true, detail: "Ran " + c }
  }

  function applyStep(step) {
    switch (step.kind) {
      case "dnd": return setDnd(step.value)
      case "audio": return setAudioOutput(step.value)
      case "wallpaper": return setWallpaper(step.value)
      case "theme": return setTheme(step.value)
      case "workspace": return focusWorkspace(step.value)
      case "applications":
        return step.desktopId
          ? launchDesktopEntry(step.desktopId, step.workspace)
          : launchApplication(step.value, step.workspace)
      case "commands": return runCommand(step.value)
    }
    return { ok: false, detail: "Unknown action \"" + step.kind + "\"" }
  }

  // ------------------------------------------------------------ activation

  property var pendingActivation: null

  function activateMode(id, options) {
    var opts = Model.isPlainObject(options) ? options : {}
    var ctx = Model.findMode(config, id)
    if (!ctx) {
      log("warn", "No mode with id \"" + String(id) + "\"")
      return false
    }
    if (ctx.enabled === false) {
      log("warn", "Mode \"" + ctx.name + "\" is disabled")
      return false
    }
    if (activating) {
      log("warn", "Ignored activation of \"" + ctx.name + "\": another activation is in flight")
      return false
    }

    // Only a full switch touches the windows that are already open.
    var windows = "keep"
    if (opts.settingsOnly !== true) {
      windows = Model.windowSwitchMode(config.behavior, opts.windows, openWindows().length > 0)
      if (windows === "ask") {
        askAboutWindows(ctx, opts)
        return true
      }
    }

    service.activating = true
    service.pendingActivation = {
      modeId: ctx.id,
      settingsOnly: opts.settingsOnly === true,
      silent: opts.silent === true,
      closeWindows: windows === "close",
      previousModeId: service.activeModeId
    }

    log("info", "Activating " + ctx.name)
    startProbe(ctx, opts.settingsOnly === true)
    return true
  }

  function startProbe(ctx, settingsOnly) {
    var binaries = []
    if (!settingsOnly && config.behavior.launchApps !== false) {
      var apps = Array.isArray(ctx.applications) ? ctx.applications : []
      for (var i = 0; i < apps.length; i++) {
        if (apps[i].enabled === false) continue
        if (apps[i].desktopId) continue
        var key = Model.parseArgv(apps[i].command).argv[0] || ""
        if (key !== "") binaries.push(key)
      }
    }
    probeProcess.command = ["bash", "-lc", probeScript, "bash"].concat(binaries)
    probeProcess.running = true
  }

  // One subprocess per activation: the environment to snapshot, plus which of
  // the configured commands actually exist.
  readonly property string probeScript:
    'printf \'WALLPAPER\\t%s\\n\' "$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null)"\n' +
    'printf \'THEME\\t%s\\n\' "$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)"\n' +
    'for bin in "$@"; do\n' +
    '  if command -v -- "$bin" >/dev/null 2>&1; then printf \'APP\\tok\\t%s\\n\' "$bin"\n' +
    '  else printf \'APP\\tmissing\\t%s\\n\' "$bin"; fi\n' +
    'done\n'

  property var probeResult: ({ wallpaper: "", theme: "", missing: ({}) })

  function parseProbe(text) {
    var out = { wallpaper: "", theme: "", missing: ({}) }
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts[0] === "WALLPAPER") out.wallpaper = parts[1] || ""
      else if (parts[0] === "THEME") out.theme = parts[1] || ""
      else if (parts[0] === "APP" && parts[1] === "missing") out.missing[parts[2] || ""] = true
    }
    return out
  }

  Process {
    id: probeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.probeResult = service.parseProbe(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) service.log("warn", "Environment probe exited " + exitCode + "; continuing without a restore snapshot")
      service.finishActivation()
    }
  }

  // The in-flight flag must come down whatever happens; a stuck one would
  // refuse every future switch.
  function finishActivation() {
    try {
      runActivation()
    } catch (e) {
      log("warn", "Activation failed: " + (e && e.message ? e.message : "error"))
    } finally {
      service.activating = false
      service.pendingActivation = null
    }
  }

  function runActivation() {
    var pending = service.pendingActivation
    service.pendingActivation = null
    if (!pending) return

    var ctx = Model.findMode(config, pending.modeId)
    if (!ctx) {
      log("warn", "Mode disappeared mid-activation")
      return
    }

    var results = []

    if (pending.previousModeId && pending.previousModeId !== ctx.id) {
      var previous = Model.findMode(config, pending.previousModeId)
      results = results.concat(runPlan(Model.deactivationPlan(previous)))
    }

    captureSnapshot(ctx)

    if (pending.closeWindows) results = results.concat(closeOpenWindows())

    var plan = Model.activationPlan(ctx, {
      settingsOnly: pending.settingsOnly,
      launchApps: config.behavior.launchApps !== false
    })
    results = results.concat(runPlan(plan, service.probeResult.missing))

    service.config = Model.setActiveMode(service.config, ctx.id)
    save()
    service.lastActivationAt = Date.now()
    service.modesUpdated()

    var summary = Model.summarize(ctx.name, results)
    log(summary.warnings > 0 ? "warn" : "info",
      "Activated " + ctx.name + (summary.warnings > 0 ? " with " + summary.warnings + " warning(s)" : ""))
    if (!pending.silent) notifySummary(ctx, summary)
    service.activationFinished(ctx.id, summary.warnings)
  }

  function runPlan(plan, missingBinaries) {
    var results = []
    var missing = Model.isPlainObject(missingBinaries) ? missingBinaries : ({})
    for (var i = 0; i < plan.length; i++) {
      var step = plan[i]
      var result
      if (step.kind === "applications" && !step.desktopId) {
        var key = Model.parseArgv(step.value).argv[0] || ""
        if (missing[key] === true) {
          result = { ok: false, detail: "\"" + key + "\" is not installed; skipped" }
        } else {
          result = safeApply(step)
        }
      } else {
        result = safeApply(step)
      }
      results.push(result)
      log(result.ok ? "info" : "warn", result.detail)
    }
    return results
  }

  function safeApply(step) {
    try {
      var result = applyStep(step)
      return Model.isPlainObject(result) ? result : { ok: true, detail: step.label }
    } catch (e) {
      return { ok: false, detail: step.label + " failed: " + (e && e.message ? e.message : "error") }
    }
  }

  // Remembers a value only when the mode is about to change it, and only if
  // nothing is remembered for it yet.
  function captureSnapshot(ctx) {
    var snapshot = Model.clone(service.previousState)

    if (ctx.notifications && ctx.notifications.dnd !== null && ctx.notifications.dnd !== undefined) {
      if (snapshot.dnd === undefined || snapshot.dnd === null) {
        var dnd = currentDnd()
        if (dnd !== null) snapshot.dnd = dnd
      }
      snapshot.appliedDnd = ctx.notifications.dnd === true
    }
    if (ctx.audio && ctx.audio.output) {
      if (!snapshot.audioOutput) {
        var out = currentAudioOutput()
        if (out !== "") snapshot.audioOutput = out
      }
      snapshot.appliedAudioOutput = String(ctx.audio.output)
    }
    if (ctx.appearance && ctx.appearance.wallpaper) {
      if (!snapshot.wallpaper && service.probeResult.wallpaper) snapshot.wallpaper = service.probeResult.wallpaper
      snapshot.appliedWallpaper = String(ctx.appearance.wallpaper)
    }
    if (ctx.appearance && ctx.appearance.theme) {
      if (!snapshot.theme && service.probeResult.theme) snapshot.theme = service.probeResult.theme
      snapshot.appliedTheme = String(ctx.appearance.theme)
    }

    service.previousState = snapshot
    saveState()
  }

  function deactivateMode(options) {
    var opts = Model.isPlainObject(options) ? options : {}
    var ctx = service.activeMode
    var results = []

    if (ctx) results = results.concat(runPlan(Model.deactivationPlan(ctx)))

    var live = {
      dnd: currentDnd(),
      audioOutput: currentAudioOutput()
    }
    results = results.concat(runPlan(Model.restorePlan(service.previousState, live)))

    service.previousState = ({})
    saveState()
    service.config = Model.setActiveMode(service.config, null)
    save()
    service.lastActivationAt = Date.now()
    service.modesUpdated()

    var name = ctx ? ctx.name : "No mode"
    log("info", ctx ? "Deactivated " + ctx.name : "No mode was active")
    if (!opts.silent && config.behavior.showNotifications !== false)
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Omara", "Omara", "No mode. " + name + " turned off."])
    service.activationFinished("", 0)
    return true
  }

  function notifySummary(ctx, summary) {
    if (config.behavior.showNotifications === false) return
    var argv = ["omarchy-notification-send", "--app-name", "Omara"]
    if (ctx.icon) argv = argv.concat(["-g", String(ctx.icon)])
    if (summary.warnings > 0) argv = argv.concat(["-u", "normal"])
    argv.push("Mode: " + ctx.name)
    if (summary.body) argv.push(summary.body)
    Quickshell.execDetached(argv)
  }

  // ---------------------------------------------------------------- capture

  // Window class -> desktop entry. byId covers apps whose class is their id,
  // startupClass is the field .desktop files exist to answer this with, and
  // heuristicLookup is Quickshell's own fuzzy fallback.
  function entryForWindowClass(windowClass) {
    var cls = String(windowClass || "").trim()
    if (cls === "") return null
    try {
      var byId = DesktopEntries.byId(cls)
      if (byId) return byId
    } catch (e) {}

    var entries = DesktopEntries.applications ? DesktopEntries.applications.values : []
    var lowered = cls.toLowerCase()
    for (var i = 0; i < entries.length; i++) {
      var startup = entries[i] && entries[i].startupClass ? String(entries[i].startupClass) : ""
      if (startup !== "" && startup.toLowerCase() === lowered) return entries[i]
    }
    try {
      var guess = DesktopEntries.heuristicLookup(cls)
      if (guess) return guess
    } catch (e2) {}
    return null
  }

  function openWindows() {
    var out = []
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < tops.length; i++) {
      var top = tops[i]
      if (!top) continue
      var ipc = top.lastIpcObject
      var cls = ipc && ipc.class ? String(ipc.class) : ""
      if (cls === "") continue
      // Special workspaces are negative and are not somewhere a mode can
      // put a window back.
      var ws = top.workspace && top.workspace.id > 0 ? top.workspace.id : null
      var title = top.title ? String(top.title) : ""
      var entry = entryForWindowClass(cls)
      out.push(entry
        ? { desktopId: String(entry.id), workspace: ws, title: title }
        : { command: cls.toLowerCase(), workspace: ws, title: title })
    }
    return out
  }

  // Graceful close: each window gets the same request the compositor sends on
  // a close button, so anything with unsaved work can still put up its prompt.
  function closeOpenWindows() {
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var closed = 0
    for (var i = 0; i < tops.length; i++) {
      var ipc = tops[i] ? tops[i].lastIpcObject : null
      var address = ipc && ipc.address ? String(ipc.address).replace(/[^0-9a-fA-Fx]/g, "") : ""
      if (address === "") continue
      var command = Hyprland.usingLua
        ? "hl.dsp.window.close({ window = \"address:" + address + "\" })"
        : "closewindow address:" + address
      try {
        Hyprland.dispatch(command)
        closed++
      } catch (e) {
        log("warn", "Could not close a window: " + (e && e.message ? e.message : "error"))
      }
    }
    return [{ ok: true, detail: "Closed " + closed + " open window(s)" }]
  }

  // ------------------------------------------------- window switch question

  property var windowQuestion: null

  function askAboutWindows(ctx, opts) {
    service.windowQuestion = { modeId: ctx.id, options: Model.clone(Model.isPlainObject(opts) ? opts : {}) }
    var message = Model.switchPromptMessage(ctx.name, openWindows().length)
    switchLoader.active = true
    if (switchLoader.item) switchLoader.item.openWith(message)
    else service.pendingSwitchMessage = message
  }

  property string pendingSwitchMessage: ""

  function answerWindowQuestion(mode) {
    var question = service.windowQuestion
    service.windowQuestion = null
    if (switchLoader.item) switchLoader.item.close()
    if (!question) return
    var opts = Model.isPlainObject(question.options) ? question.options : {}
    opts.windows = String(mode)
    activateMode(question.modeId, opts)
  }

  function cancelWindowQuestion() {
    service.windowQuestion = null
    service.pendingSwitchMessage = ""
    if (switchLoader.item) switchLoader.item.close()
  }

  Loader {
    id: switchLoader
    active: false
    asynchronous: true
    source: Qt.resolvedUrl("SwitchDialog.qml")
    onLoaded: {
      if (!item) return
      item.service = service
      item.answered.connect(function(mode) { service.answerWindowQuestion(mode) })
      item.cancelled.connect(function() { service.cancelWindowQuestion() })
      if (service.pendingSwitchMessage !== "") {
        item.openWith(service.pendingSwitchMessage)
        service.pendingSwitchMessage = ""
      }
    }
    onStatusChanged: if (status === Loader.Error)
      service.log("warn", "Omara switch dialog failed to load: " + (errorString ? errorString() : "unknown error"))
  }

  // ---------------------------------------------------------------- themes

  property var themes: []

  readonly property string themeScript:
    'find -L "$OMARCHY_PATH/themes" "$HOME/.config/omarchy/themes" ' +
    '-mindepth 1 -maxdepth 1 -type d -printf \'%f\\n\' 2>/dev/null | sort -u\n'

  function refreshThemes() {
    if (themeProcess.running) return
    themeProcess.command = ["bash", "-lc", themeScript]
    themeProcess.running = true
  }

  Process {
    id: themeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.themes = Model.themeList(String(text || "").split("\n"))
    }
  }

  property string captureName: ""

  // Wallpaper and theme live on disk, so capture waits on the same probe
  // activation uses. Everything else is already in memory.
  function captureCurrentSetup(name) {
    if (captureProcess.running) return false
    service.captureName = String(name || "")
    captureProcess.command = ["bash", "-lc", probeScript, "bash"]
    captureProcess.running = true
    return true
  }

  Process {
    id: captureProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.probeResult = service.parseProbe(text)
    }
    onExited: service.finishCapture()
  }

  function finishCapture() {
    var focused = Hyprland.focusedWorkspace
    var fields = Model.captureMode({
      name: service.captureName,
      description: "Captured from the desktop",
      workspace: focused && focused.id > 0 ? focused.id : null,
      dnd: currentDnd(),
      audioOutput: currentAudioOutput(),
      wallpaper: service.probeResult.wallpaper,
      theme: service.probeResult.theme,
      windows: openWindows()
    })
    service.captureName = ""

    var id = createModeFrom(fields)
    log("info", "Captured " + fields.applications.length + " application(s) from the desktop")
    requestEditor(id)
    return id
  }

  // ------------------------------------------------------------------- CRUD

  function createModeFrom(fields) {
    var result = Model.createMode(service.config, fields)
    applyConfig(result.config, "Created mode " + result.mode.name)
    return result.mode.id
  }

  function createFromTemplate(key) {
    var ctx = Model.templateMode(key, Model.modeIds(service.config))
    if (!ctx) return ""
    return createModeFrom(ctx)
  }

  function updateModeFields(id, fields) {
    var result = Model.updateMode(service.config, id, fields)
    if (result.error) { log("warn", result.error); return false }
    applyConfig(result.config, "Saved mode " + result.mode.name)
    return true
  }

  function duplicateMode(id) {
    var source = Model.findMode(service.config, id)
    if (!source) return ""
    var result = Model.importModes(service.config, [source], "copy")
    if (result.added.length === 0) return ""
    applyConfig(result.config, "Duplicated " + source.name)
    return result.added[result.added.length - 1]
  }

  function reorderMode(id, delta) {
    var result = Model.moveMode(service.config, id, delta)
    if (!result.moved) return false
    applyConfig(result.config, "")
    return true
  }

  function removeMode(id) {
    var ctx = Model.findMode(service.config, id)
    var result = Model.deleteMode(service.config, id)
    if (!result.removed) return false
    applyConfig(result.config, "Deleted mode " + (ctx ? ctx.name : id))
    return true
  }

  function setBehavior(key, value) {
    var next = Model.clone(service.config)
    next.behavior[String(key)] = value === true
    applyConfig(next, "")
    return true
  }

  function importFromText(text, mode) {
    var parsed = Model.parseImport(text)
    if (parsed.error) { log("warn", "Import failed: " + parsed.error); return { ok: false, error: parsed.error } }
    var result = Model.importModes(service.config, parsed.modes, mode)
    applyConfig(result.config, "Imported " + (result.added.length + result.replaced.length) + " mode(s)")
    return { ok: true, added: result.added, replaced: result.replaced, skipped: result.skipped }
  }

  function exportText(ids) {
    return JSON.stringify(Model.exportPayload(service.config, ids), null, 2) + "\n"
  }

  // ---------------------------------------------------------------- triggers

  Connections {
    target: Hyprland
    enabled: service.configLoaded && service.config.behavior.triggersEnabled === true
    function onRawEvent(event) {
      if (!event || String(event.name) !== "openwindow") return
      service.handleWindowOpened(event.data)
    }
  }

  function handleWindowOpened(data) {
    var parsed = Model.parseOpenWindowEvent(data)
    if (!parsed) return
    var decision = Model.evaluateTrigger(service.config, parsed, {
      now: Date.now(),
      lastActivationAt: service.lastActivationAt,
      cooldownMs: Model.TRIGGER_COOLDOWN_MS
    })
    if (decision.action === "ignore") return

    var ctx = Model.findMode(service.config, decision.modeId)
    if (!ctx) return

    if (decision.action === "switch") {
      log("info", "Trigger: " + decision.reason + " → switching to " + ctx.name)
      activateMode(ctx.id, { windows: "keep" })
      return
    }

    log("info", "Trigger: " + decision.reason + " → asking about " + ctx.name)
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "Omara",
      "-u", "normal",
      "Switch to " + ctx.name + "?",
      decision.reason + ", click to switch",
      "--exec", "omarchy-shell", "-q", "omara", "activateWindows", ctx.id, "keep"
    ])
  }

  // ------------------------------------------------------------------ editor

  function closeEditor() {
    if (editorLoader.item) editorLoader.item.close()
  }

  Loader {
    id: editorLoader
    active: false
    asynchronous: true
    source: Qt.resolvedUrl("EditorWindow.qml")
    onLoaded: {
      if (!item) return
      item.service = service
      if (service.pendingEditorMode !== null) {
        item.openFor(service.pendingEditorMode)
        service.pendingEditorMode = null
      }
    }
    onStatusChanged: if (status === Loader.Error)
      service.log("warn", "Omara editor failed to load: " + (errorString ? errorString() : "unknown error"))
  }

  property var pendingEditorMode: null

  onPendingEditorModeChanged: if (pendingEditorMode !== null) editorLoader.active = true

  function requestEditor(modeId) {
    if (editorLoader.item) {
      editorLoader.item.openFor(String(modeId || ""))
      return
    }
    service.pendingEditorMode = String(modeId || "")
  }

  // --------------------------------------------------------------------- IPC

  IpcHandler {
    target: "omara"

    function list(): string {
      var out = []
      for (var i = 0; i < service.modes.length; i++) {
        var c = service.modes[i]
        out.push({
          id: c.id,
          name: c.name,
          icon: c.icon,
          description: c.description,
          enabled: c.enabled,
          active: c.id === service.activeModeId
        })
      }
      return JSON.stringify(out)
    }

    function current(): string {
      return service.activeModeId
    }

    function activate(id: string): string {
      return service.activateMode(String(id)) ? "ok" : "error"
    }

    // Explicit window handling, so scripts and notifications never wait on a dialog.
    function activateWindows(id: string, mode: string): string {
      var want = String(mode || "")
      if (want !== "close" && want !== "keep") return "error"
      return service.activateMode(String(id), { windows: want }) ? "ok" : "error"
    }

    function deactivate(): string {
      return service.deactivateMode() ? "ok" : "error"
    }

    function edit(id: string): string {
      service.requestEditor(String(id || ""))
      return "ok"
    }

    function capture(name: string): string {
      return service.captureCurrentSetup(String(name || "")) ? "ok" : "busy"
    }

    function manage(): string {
      service.requestEditor("")
      return "ok"
    }

    function close(): string {
      service.closeEditor()
      return "ok"
    }

    function activity(): string {
      return JSON.stringify(service.activityLog)
    }

    function reload(): string {
      configFile.reload()
      return "ok"
    }

    function exportAll(): string {
      return service.exportText(null)
    }

    function exportOne(id: string): string {
      return service.exportText([String(id)])
    }

    function show(): string {
      return JSON.stringify({
        active: service.activeModeId,
        count: service.modes.length,
        triggersEnabled: service.config.behavior.triggersEnabled === true,
        readOnly: service.configReadOnly
      })
    }
  }

  // ---------------------------------------------------------------- startup

  Component.onCompleted: {
    stateFile.reload()
    configFile.reload()
  }

  property bool restoreAttempted: false
  onConfigLoadedChanged: {
    if (!configLoaded || restoreAttempted) return
    restoreAttempted = true
    if (config.behavior.restoreOnStart !== true) return
    if (!activeModeId) return
    Qt.callLater(function() {
      service.activateMode(service.activeModeId, { settingsOnly: true, silent: true })
    })
  }
}

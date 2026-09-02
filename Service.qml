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

  // --------------------------------------------------- subprocess boundaries

  // Every producer this service reads from runs under a deadline enforced
  // outside the shell. `timeout` puts the child in its own process group and
  // sends TERM, then KILL after the grace period, so a wedged tool cannot
  // outlive the wait or leave the group orphaned. The QML watchdogs beside
  // each Process are the second line, for a child that is unkillable rather
  // than merely slow: they release whatever was waiting on it.
  function bounded(seconds, argv) {
    return ["timeout", "-k", "2", String(seconds)].concat(argv)
  }

  // Actions are the other case, and they need the opposite default. Killing a
  // producer is free — all we wanted was its output. Killing omarchy-theme-set
  // half way through leaves a partly applied theme, which is worse than
  // waiting, so an action is not killed at the reporting deadline: we stop
  // waiting and say so, and it finishes on its own. The far backstop is only
  // there so a genuinely wedged process cannot live forever.
  readonly property int actionKillSec: 120

  function boundedAction(argv) {
    return ["timeout", "-k", "5", String(actionKillSec)].concat(argv)
  }

  // ------------------------------------------------- supervised subprocesses
  //
  // Quickshell.execDetached hands back nothing: no start, no exit code, no
  // deadline. Anything whose failure changes what a mode actually did runs
  // through here instead, so an activation reports what happened rather than
  // what it asked for.
  //
  // Three things deliberately stay detached, for one reason: they must outlive
  // the shell. Supervising a process means parenting it, and a parented
  // application dies the next time omarchy-restart-shell runs.
  //
  //   onActivate / onDeactivate  the documented hook capability
  //   raw application commands   `exec "$@"` becomes the application itself
  //   Hyprland-placed launches   the compositor owns those, not us
  //
  // Desktop entries are supervised even though they start applications, because
  // uwsm-app is a client: it asks the app daemon to launch under systemd and
  // exits. Its exit code is the launch verdict, and killing it at the deadline
  // cannot reach the application.
  //
  // Nothing here collects stdout or stderr. The exit code is the whole answer,
  // and output that is never collected is the only ceiling that cannot be
  // exceeded.

  // Comfortably clear of three contending omarchy-theme-set runs, which take
  // about six seconds each and serialise; a single switch never comes close.
  readonly property int actionDeadlineSec: 30

  property int nextRunId: 1
  property var runRegistry: ({})

  // The Process and its deadline need a common parent to live under, since a
  // Process has no default property of its own to hold a Timer.
  Component {
    id: supervisedRun

    Item {
      id: run
      property int runId: 0
      property string label: ""
      property var argv: []
      property bool settled: false

      function start() { proc.running = true }

      function finish(code) {
        if (run.settled) return
        run.settled = true
        runDeadline.stop()
        service.settleRun(run.runId, code === 0, code === 0 ? ""
          : ((code === 124 || code === 137)
            ? run.label + " did not report back within " + service.actionDeadlineSec + "s"
            : run.label + " exited " + code))
        run.destroy()
      }

      Process {
        id: proc
        command: run.argv
        onExited: function(exitCode) { run.finish(exitCode) }
      }

      // Second line behind `timeout`, for a child that is unkillable rather
      // than slow. Whatever is waiting on this run gets released either way.
      Timer {
        id: runDeadline
        interval: (service.actionDeadlineSec + 3) * 1000
        repeat: false
        running: true
        // Stop waiting, do not kill. The process keeps going and finishes its
        // work; we have simply stopped holding a verdict open for it.
        onTriggered: run.finish(124)
      }
    }
  }

  // Returns a token an activation step can carry, so the step's own result is
  // amended once the process actually reports. A non-blocking run is one whose
  // failure is worth a log line but should not hold up the verdict.
  function runSupervised(argv, label, blocking) {
    var id = service.nextRunId++
    var name = String(label || (argv && argv[0]) || "command")
    service.runRegistry[id] = { settled: false, ok: true, detail: "", blocking: blocking !== false }
    var obj = supervisedRun.createObject(service, {
      runId: id, label: name, argv: boundedAction(argv)
    })
    if (!obj) {
      settleRun(id, false, name + " could not be started")
      return id
    }
    obj.start()
    return id
  }

  function notify(argv) {
    runSupervised(argv, "omarchy-notification-send", false)
  }

  function settleRun(id, ok, detail) {
    var rec = service.runRegistry[id]
    if (!rec || rec.settled) return
    rec.settled = true
    rec.ok = ok
    rec.detail = detail
    if (!rec.blocking) {
      // Nobody is holding a verdict open for this one, so it reports itself
      // and clears its own entry rather than sitting in the registry forever.
      if (!ok) log("warn", detail)
      delete service.runRegistry[id]
      return
    }
    checkAwaiting()
  }

  // ------------------------------------------------------------- path guard
  //
  // FileView is path-based: it takes a name, opens it, and reads to the end.
  // There is no descriptor-relative read, no O_NOFOLLOW and no size ceiling in
  // that API, so the check has to happen before the path is handed over. A
  // FIFO at omara.json would otherwise block the shell on first read, and a
  // symlink would redirect where the config is persisted.
  //
  // This closes the standing cases — a hostile or broken path already sitting
  // there, and a directory other users can write to. It is not a defence
  // against a live race by someone who can already write to your config
  // directory; nothing expressible against this API would be.

  readonly property int fileMaxBytes: 4194304
  readonly property int guardDeadlineSec: 5

  property bool guardSettled: false
  property bool configPathOk: false
  property bool statePathOk: false
  property string configRefusal: ""

  readonly property string guardScript:
    'uid=$(id -u)\n' +
    'limit=$1\n' +
    'shift\n' +
    'for spec in "$@"; do\n' +
    '  key=${spec%%=*}\n' +
    '  path=${spec#*=}\n' +
    '  dir=${path%/*}\n' +
    '  verdict=ok\n' +
    '  detail=\n' +
    '  if info=$(stat -c \'%F|%u|%s\' -- "$path" 2>/dev/null); then\n' +
    '    type=${info%%|*}\n' +
    '    rest=${info#*|}\n' +
    '    owner=${rest%%|*}\n' +
    '    size=${rest##*|}\n' +
    '    case $type in\n' +
    '      "regular file" | "regular empty file") ;;\n' +
    '      *) verdict=refuse; detail="it is not a regular file (found: $type)" ;;\n' +
    '    esac\n' +
    '    if [ "$verdict" != ok ]; then\n' +
    '      :\n' +
    '    elif [ "$owner" != "$uid" ]; then\n' +
    '      verdict=refuse; detail="it is owned by uid $owner, not by you"\n' +
    '    elif [ "$size" -gt "$limit" ]; then\n' +
    '      verdict=refuse; detail="it is $size bytes, past the $limit byte ceiling"\n' +
    '    fi\n' +
    '  fi\n' +
    '  if [ "$verdict" = ok ] && dinfo=$(stat -c \'%F|%u|%a\' -- "$dir" 2>/dev/null); then\n' +
    '    dtype=${dinfo%%|*}\n' +
    '    drest=${dinfo#*|}\n' +
    '    downer=${drest%%|*}\n' +
    '    dmode=${drest##*|}\n' +
    '    other=${dmode#"${dmode%?}"}\n' +
    '    head2=${dmode%?}\n' +
    '    group=${head2#"${head2%?}"}\n' +
    '    if [ "$dtype" != directory ]; then\n' +
    '      verdict=refuse; detail="$dir is not a directory (found: $dtype)"\n' +
    '    elif [ "$downer" != "$uid" ]; then\n' +
    '      verdict=refuse; detail="$dir is owned by uid $downer, not by you"\n' +
    '    else\n' +
    '      case $other in 2|3|6|7) verdict=refuse; detail="$dir is writable by any user (mode $dmode)" ;; esac\n' +
    '      case $group in 2|3|6|7) [ "$verdict" = ok ] && verdict=warn && detail="$dir is group-writable (mode $dmode)" ;; esac\n' +
    '    fi\n' +
    '  fi\n' +
    '  printf \'GUARD\\t%s\\t%s\\t%s\\n\' "$key" "$verdict" "$detail"\n' +
    'done\n'

  function checkPaths() {
    if (guardProcess.running) return
    guardProcess.command = bounded(guardDeadlineSec, [
      "bash", "-lc", guardScript, "bash", String(service.fileMaxBytes),
      "config=" + service.configPath, "state=" + service.statePath
    ])
    guardProcess.running = true
    guardWatchdog.restart()
  }

  // Runs at startup and again on every reconcile tick, so this has to be quiet
  // when nothing has changed. refuseConfig() dedupes on the reason.
  function applyGuard(report) {
    var config = report ? report["config"] : null
    var state = report ? report["state"] : null
    var configOk = !config || config.verdict !== "refuse"
    var stateOk = !state || state.verdict !== "refuse"

    if (config && config.verdict === "warn" && !service.guardSettled)
      log("warn", "omara.json: " + config.detail)

    if (configOk) service.configRefusal = ""
    else refuseConfig(config.detail)

    if (!stateOk && (!service.guardSettled || service.statePathOk))
      log("warn", "Not reading or writing omara-state.json: " + state.detail)

    var firstSettle = !service.guardSettled
    service.configPathOk = configOk
    service.statePathOk = stateOk
    service.guardSettled = true

    if (!firstSettle) return
    if (stateOk) stateFile.reload()
    if (configOk) configFile.reload()
  }

  // Refusing is not destructive: nothing on disk is touched, and `configLoaded`
  // stays false, which is what stops save() from ever writing through.
  function refuseConfig(detail) {
    var reason = String(detail || "it did not pass the path check")
    if (service.configRefusal === reason) return
    service.configRefusal = reason
    log("warn", "Refusing to read or write omara.json: " + reason)
    notify([
      "omarchy-notification-send", "--app-name", "Omara", "-u", "critical", "Omara",
      "omara.json was not used because " + reason
        + ". Omara started with no modes and will not write to that path. Nothing was changed or deleted."
    ])
  }

  Process {
    id: guardProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.applyGuard(Model.parseGuardOutput(String(text || "")))
    }
    onExited: function(exitCode) {
      guardWatchdog.stop()
      // Fail open only when the check itself could not run. A positively
      // detected hazard fails closed; an unavailable `stat` must not lock a
      // working install out of its own config.
      if (exitCode !== 0 && !service.guardSettled) {
        log("warn", "Could not check the config paths (exit " + exitCode + "); continuing")
        service.configPathOk = true
        service.statePathOk = true
        service.guardSettled = true
      }
    }
  }

  Timer {
    id: guardWatchdog
    interval: (service.guardDeadlineSec + 3) * 1000
    repeat: false
    onTriggered: {
      if (guardProcess.running) guardProcess.running = false
      if (service.guardSettled) return
      log("warn", "The config path check did not finish in " + service.guardDeadlineSec + "s; continuing")
      service.configPathOk = true
      service.statePathOk = true
      service.guardSettled = true
    }
  }

  // A reloaded or torn-down plugin must not leave children running. Every
  // Process here is bounded by `timeout` as well, so an escaped one still ends
  // on its own; this is what makes the common case immediate.
  Component.onDestruction: {
    guardProcess.running = false
    probeProcess.running = false
    captureProcess.running = false
    themeProcess.running = false
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
    if (parsed.recovered) service.backupBrokenConfig(raw)
    service.configLoaded = true
    service.modesUpdated()
  }

  // The recovery copy is the bytes that were actually read, not a second open
  // of the same name. Copying by path re-resolved it, so what landed in the
  // backup was whatever the name pointed at by then rather than what failed to
  // parse — and a detached copy nobody was watching did the writing.
  function backupBrokenConfig(raw) {
    var backup = service.configPath + ".corrupt"
    backupFile.path = backup
    backupFile.setText(String(raw === undefined || raw === null ? "" : raw))
    log("warn", "Saved the unreadable omara.json as " + backup + " before starting from defaults")
    notify([
      "omarchy-notification-send", "--app-name", "Omara", "-u", "normal",
      "Omara", "omara.json could not be read. A copy was saved as omara.json.corrupt."
    ])
  }

  FileView {
    id: backupFile
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: configFile
    path: service.configPathOk ? service.configPath : ""
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
    onLoadFailed: if (service.configPathOk && !service.configLoaded) service.loadConfig("")
  }

  property bool configFileSeen: false

  // A file watcher dies when the file is replaced by rename; this heals it.
  // The guard runs again first: a path that has become a FIFO or a symlink
  // since startup must not be reopened just because it once passed.
  Timer {
    id: reconcileTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: {
      service.checkPaths()
      if (service.configPathOk) configFile.reload()
    }
  }

  FileView {
    id: stateFile
    path: service.statePathOk ? service.statePath : ""
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
      runSupervised(["omarchy-shell", "-q", "omarchy.indicators", "refresh"], "indicator refresh", false)
      return { ok: true, detail: on ? "Do Not Disturb on" : "Do Not Disturb off" }
    }
    var run = runSupervised(["omarchy-shell", "-q", "notifications", "setDnd", on ? "on" : "off"], "setDnd")
    return { ok: true, detail: on ? "Do Not Disturb on" : "Do Not Disturb off", run: run }
  }

  function setAudioOutput(name) {
    var node = findSink(name)
    if (!node) return { ok: false, detail: "Audio output \"" + name + "\" is not available; kept the current output" }
    Pipewire.preferredDefaultAudioSink = node
    var run = 0
    if (node.id !== undefined && node.name)
      run = runSupervised(["omarchy-audio-output-set-default", String(node.id), String(node.name)],
        "omarchy-audio-output-set-default")
    return { ok: true, detail: "Audio output → " + String(node.description || node.name), run: run }
  }

  function setWallpaper(path) {
    var p = String(path || "")
    if (p === "") return { ok: false, detail: "No wallpaper set" }
    var run = runSupervised(["omarchy-theme-bg-set", p], "omarchy-theme-bg-set")
    return { ok: true, detail: "Wallpaper → " + p, run: run }
  }

  function setTheme(name) {
    var n = String(name || "")
    if (n === "") return { ok: false, detail: "No theme set" }
    var run = runSupervised(["omarchy-theme-set", n], "omarchy-theme-set")
    return { ok: true, detail: "Theme → " + n, run: run }
  }

  function focusWorkspace(target) {
    var id = Model.workspaceRef(target)
    if (id === "")
      return { ok: false, detail: "\"" + String(target) + "\" is not a workspace Hyprland can name; skipped" }
    var command = Hyprland.usingLua
      ? "hl.dsp.focus({ workspace = " + Model.luaQuote(id) + " })"
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

  // Hyprland's exec rule follows the pid it spawned, which Chromium and friends
  // drop when they re-exec. Remember where each launch was meant to land and
  // move the window if it turns up somewhere else.
  property var pendingPlacements: []

  // Where the running mode meant to leave you. A window that shows up on the
  // wrong workspace takes focus with it, so put focus back after moving it.
  property string landingWorkspace: ""

  function expectPlacement(keys, workspace) {
    if (workspace === null || workspace === undefined) return
    if (!Array.isArray(keys) || keys.length === 0) return
    var list = Model.prunePlacements(service.pendingPlacements, Date.now())
    list.push({ keys: keys, workspace: String(workspace), at: Date.now() })
    service.pendingPlacements = list
  }

  function placeWindow(address, workspace) {
    var addr = String(address || "").replace(/[^0-9a-fA-Fx]/g, "")
    if (addr === "") return
    if (addr.indexOf("0x") !== 0) addr = "0x" + addr
    // The keyword form is one comma-separated argument list, so a workspace
    // that is not a workspace would read as extra arguments. Refuse it.
    var target = Model.workspaceRef(workspace)
    if (target === "") return
    Hyprland.dispatch(Hyprland.usingLua
      ? "hl.dsp.window.move({ window = \"address:" + addr + "\", workspace = "
        + Model.luaQuote(target) + ", follow = false })"
      : "movetoworkspacesilent " + target + ",address:" + addr)
  }

  function handleWindowPlacement(data) {
    if (service.pendingPlacements.length === 0) return
    var parsed = Model.parseOpenWindowEvent(data)
    if (!parsed) return
    var now = Date.now()
    var index = Model.matchPlacement(service.pendingPlacements, parsed.windowClass, now)
    if (index < 0) {
      service.pendingPlacements = Model.prunePlacements(service.pendingPlacements, now)
      return
    }
    var wanted = String(service.pendingPlacements[index].workspace)
    var list = service.pendingPlacements.slice()
    list.splice(index, 1)
    service.pendingPlacements = Model.prunePlacements(list, now)
    if (String(parsed.workspace) === wanted) return
    placeWindow(parsed.address, wanted)
    log("info", "Moved " + parsed.windowClass + " to workspace " + wanted)
    if (service.landingWorkspace !== "") focusWorkspace(service.landingWorkspace)
  }

  // Placement without focus theft, so a mode can lay out several workspaces.
  // The rule refuses a workspace outside Hyprland's grammar, in which case the
  // application still launches, just wherever you happen to be.
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
    if (workspace !== null && workspace !== undefined && Model.workspaceRef(workspace) === "")
      return { ok: false, detail: "\"" + String(workspace) + "\" is not a workspace Hyprland can name; skipped" }
    var where = workspace === null || workspace === undefined ? "" : " on workspace " + workspace

    if (where !== "") {
      expectPlacement(Model.placementKeys(desktopId, "", entry.startupClass), workspace)
      launchOnWorkspace(workspace, desktopLaunchCommand(desktopId))
      return { ok: true, detail: "Launched " + name + where }
    }
    if (appLibrary && typeof appLibrary.launch === "function") {
      appLibrary.launch(desktopId, name)
      return { ok: true, detail: "Launched " + name }
    }
    // uwsm-app asks the app daemon to launch under systemd and exits, so its
    // exit code is the launch verdict and the deadline cannot reach the app.
    var run = runSupervised(["uwsm-app", "--", "gtk-launch", desktopId + ".desktop"], name)
    return { ok: true, detail: "Launched " + name, run: run }
  }

  function launchApplication(command, workspace) {
    var parsed = Model.parseArgv(command)
    if (parsed.argv.length === 0)
      return { ok: false, detail: "Empty application command" }
    if (parsed.unterminated)
      return { ok: false, detail: "Unbalanced quote in \"" + command + "\"" }

    if (workspace !== null && workspace !== undefined) {
      if (Model.workspaceRef(workspace) === "")
        return { ok: false, detail: "\"" + String(workspace) + "\" is not a workspace Hyprland can name; skipped" }
      var quoted = []
      for (var i = 0; i < parsed.argv.length; i++) quoted.push(Util.shellQuote(parsed.argv[i]))
      expectPlacement(Model.placementKeys("", parsed.argv[0], ""), workspace)
      launchOnWorkspace(workspace, quoted.join(" "))
      return { ok: true, detail: "Launched " + parsed.argv[0] + " on workspace " + workspace }
    }

    // Detached on purpose: `exec "$@"` becomes the application, so supervising
    // this would parent it to the shell and kill it on the next shell restart.
    // Whether it could start at all is answered ahead of time by the probe,
    // which is why runPlan skips a command that is not installed.
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(parsed.argv))
    return { ok: true, detail: "Launched " + parsed.argv[0] }
  }

  // The documented hook capability, and detached for the same reason as a raw
  // launch: a hook that starts something is entitled to outlive the shell.
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
    // Supersession: one probe at a time. A leftover from an activation that
    // never settled is killed rather than raced against.
    if (probeProcess.running) probeProcess.running = false
    service.probeSettled = false
    probeProcess.command = bounded(probeDeadlineSec,
      ["bash", "-lc", probeScript, "bash"].concat(binaries.slice(0, probeMaxBinaries)))
    probeProcess.running = true
    probeWatchdog.restart()
  }

  // One subprocess per activation: the environment to snapshot, plus which of
  // the configured commands actually exist.
  //
  // Every producer here is capped at the source. `theme.name` in particular is
  // read with `head -c`, not `cat`: if that path is a FIFO the read still
  // blocks, which is what the enclosing `timeout` is for.
  readonly property int probeDeadlineSec: 10
  readonly property int probeMaxBinaries: 256
  readonly property string probeScript:
    'ws=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null | head -c 4096)\n' +
    'printf \'WALLPAPER\\t%s\\n\' "$ws"\n' +
    'th=$(head -c 256 "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null | head -n 1)\n' +
    'printf \'THEME\\t%s\\n\' "$th"\n' +
    'n=0\n' +
    'for bin in "$@"; do\n' +
    '  n=$((n + 1)); [ "$n" -gt 256 ] && break\n' +
    '  b=$(printf %s "$bin" | head -c 256)\n' +
    '  if command -v -- "$b" >/dev/null 2>&1; then printf \'APP\\tok\\t%s\\n\' "$b"\n' +
    '  else printf \'APP\\tmissing\\t%s\\n\' "$b"; fi\n' +
    'done\n'

  property var probeResult: Model.emptyProbeResult()
  property bool probeSettled: false

  // Exit and deadline both land here, and only the first one counts. A probe
  // that never settled would leave `activating` stuck and refuse every future
  // switch, so the deadline has to be able to finish the activation itself.
  function settleProbe(warning) {
    if (service.probeSettled) return
    service.probeSettled = true
    probeWatchdog.stop()
    if (warning) log("warn", warning)
    service.finishActivation()
  }

  Process {
    id: probeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.probeResult = Model.parseProbeOutput(text)
    }
    onExited: function(exitCode) {
      service.settleProbe(exitCode === 0 ? ""
        : "Environment probe exited " + exitCode + "; continuing without a restore snapshot")
    }
  }

  Timer {
    id: probeWatchdog
    interval: (service.probeDeadlineSec + 3) * 1000
    repeat: false
    onTriggered: {
      if (probeProcess.running) probeProcess.running = false
      service.settleProbe("Environment probe did not finish in "
        + service.probeDeadlineSec + "s; continuing without a restore snapshot")
    }
  }

  // The in-flight flag must come down whatever happens; a stuck one would
  // refuse every future switch.
  function finishActivation() {
    try {
      runActivation()
    } catch (e) {
      log("warn", "Activation failed: " + (e && e.message ? e.message : "error"))
      abandonActivation()
    }
  }

  // The early exits, which never got as far as issuing a plan to release.
  function abandonActivation() {
    service.activating = false
    service.pendingActivation = null
  }

  function runActivation() {
    var pending = service.pendingActivation
    service.pendingActivation = null
    if (!pending) {
      abandonActivation()
      return
    }

    var ctx = Model.findMode(config, pending.modeId)
    if (!ctx) {
      log("warn", "Mode disappeared mid-activation")
      abandonActivation()
      return
    }

    var results = []

    if (pending.previousModeId && pending.previousModeId !== ctx.id) {
      var previous = Model.findMode(config, pending.previousModeId)
      results = results.concat(runPlan(Model.deactivationPlan(previous)))
    }

    service.landingWorkspace = ctx.workspaces
      ? Model.workspaceRef(ctx.workspaces.target) : ""

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

    // The mode is active and its plan has been issued, so the next switch is
    // free to start. What waits is the verdict, not the door: omarchy-theme-set
    // alone takes about six seconds, and holding a switch closed for that long
    // would make every theme change feel like a hang.
    var silent = pending.silent === true
    service.activating = false
    service.pendingActivation = null

    // An activation must still not announce success while the programs it
    // needed are failing, so the summary, the notification and the finished
    // signal all wait for what actually happened.
    awaitRuns(results, function(outcome) {
      var summary = Model.summarize(ctx.name, outcome)
      log(summary.warnings > 0 ? "warn" : "info",
        "Activated " + ctx.name + (summary.warnings > 0 ? " with " + summary.warnings + " warning(s)" : ""))
      if (!silent) notifySummary(ctx, summary)
      service.activationFinished(ctx.id, summary.warnings)
    })
  }

  // ------------------------------------------------------------- the verdict
  //
  // A plan finishes when its supervised steps have reported, not when the last
  // one was asked to start. Deactivation waits the same way activation does:
  // both restore settings through the same functions, so both hand back the
  // same tokens and both would otherwise announce a result they do not have.

  // Jobs are independent. Serialising them behind one slot meant a slow
  // deactivation held an activation's verdict open behind it, and `activating`
  // stayed true the whole time, so the next switch was refused as "already in
  // flight" for something that had already finished its work.
  property var awaitJobs: []

  function awaitRuns(results, done) {
    var ids = []
    for (var i = 0; i < results.length; i++)
      if (results[i] && results[i].run) ids.push(results[i].run)
    service.awaitJobs = service.awaitJobs.concat([
      { results: results, ids: ids, done: done, at: Date.now() }
    ])
    if (!awaitSweep.running) awaitSweep.start()
    checkAwaiting()
  }

  function checkAwaiting() {
    var jobs = service.awaitJobs
    if (jobs.length === 0) return
    var waiting = []
    var ready = []

    for (var j = 0; j < jobs.length; j++) {
      var pending = false
      for (var i = 0; i < jobs[j].ids.length; i++) {
        var rec = service.runRegistry[jobs[j].ids[i]]
        if (rec && !rec.settled) { pending = true; break }
      }
      if (pending) waiting.push(jobs[j])
      else ready.push(jobs[j])
    }

    if (ready.length === 0) return
    // Reassign before finishing: a done() that starts another job must append
    // to the new list, not to one we are about to overwrite.
    service.awaitJobs = waiting
    for (var k = 0; k < ready.length; k++) finishJob(ready[k])
    if (service.awaitJobs.length === 0) awaitSweep.stop()
  }

  function finishJob(job) {
    // A step carrying a token was not logged when it ran. This is where it
    // gets its one line, and the line says what actually happened.
    var results = job.results
    for (var i = 0; i < results.length; i++) {
      var id = results[i] ? results[i].run : 0
      if (!id) continue
      var rec = service.runRegistry[id]
      delete service.runRegistry[id]
      if (!rec || rec.ok) { log("info", results[i].detail); continue }
      results[i].ok = false
      results[i].detail = rec.detail
      log("warn", rec.detail)
    }

    try {
      if (typeof job.done === "function") job.done(results)
    } catch (e) {
      log("warn", "Could not finish: " + (e && e.message ? e.message : "error"))
    }
  }

  // One sweep for every job, so an action that never reports back cannot hold
  // its own job open — or, now, anyone else's.
  Timer {
    id: awaitSweep
    interval: 2000
    repeat: true
    onTriggered: {
      var now = Date.now()
      var limit = (service.actionDeadlineSec + 8) * 1000
      var jobs = service.awaitJobs
      for (var j = 0; j < jobs.length; j++) {
        if (now - jobs[j].at < limit) continue
        for (var i = 0; i < jobs[j].ids.length; i++)
          service.settleRun(jobs[j].ids[i], false, "an action never reported back")
      }
      service.checkAwaiting()
      if (service.awaitJobs.length === 0) awaitSweep.stop()
    }
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
      if (!result.run) log(result.ok ? "info" : "warn", result.detail)
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
    var silent = opts.silent === true
    awaitRuns(results, function() {
      log("info", ctx ? "Deactivated " + ctx.name : "No mode was active")
      if (!silent && config.behavior.showNotifications !== false)
        notify(["omarchy-notification-send", "--app-name", "Omara", "Omara", "No mode. " + name + " turned off."])
      service.activationFinished("", 0)
    })
    return true
  }

  function notifySummary(ctx, summary) {
    if (config.behavior.showNotifications === false) return
    var argv = ["omarchy-notification-send", "--app-name", "Omara"]
    if (ctx.icon) argv = argv.concat(["-g", String(ctx.icon)])
    if (summary.warnings > 0) argv = argv.concat(["-u", "normal"])
    argv.push("Mode: " + ctx.name)
    if (summary.body) argv.push(summary.body)
    notify(argv)
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

  // `-L` stays: Omarchy themes are routinely symlinked directories, and
  // dropping it would empty the picker for anyone who installs them that way.
  // `-maxdepth 1` is what makes following safe — the scan only ever stats the
  // immediate children of two known roots, so it cannot recurse or loop. The
  // count and byte caps bound the result, and `timeout` bounds the wait.
  readonly property int themeDeadlineSec: 10
  readonly property string themeScript:
    'find -L "$OMARCHY_PATH/themes" "$HOME/.config/omarchy/themes" ' +
    '-mindepth 1 -maxdepth 1 -type d -printf \'%f\\n\' 2>/dev/null ' +
    '| head -n 512 | head -c 65536 | sort -u\n'

  function refreshThemes() {
    if (themeProcess.running) return
    themeProcess.command = bounded(themeDeadlineSec, ["bash", "-lc", themeScript])
    themeProcess.running = true
    themeWatchdog.restart()
  }

  Process {
    id: themeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.themes = Model.themeList(String(text || "").split("\n"))
    }
    onExited: themeWatchdog.stop()
  }

  Timer {
    id: themeWatchdog
    interval: (service.themeDeadlineSec + 3) * 1000
    repeat: false
    onTriggered: {
      if (!themeProcess.running) return
      themeProcess.running = false
      service.log("warn", "Theme scan did not finish in " + service.themeDeadlineSec + "s; kept the previous list")
    }
  }

  property string captureName: ""

  // Wallpaper and theme live on disk, so capture waits on the same probe
  // activation uses. Everything else is already in memory.
  function captureCurrentSetup(name) {
    if (captureProcess.running) return false
    service.captureName = String(name || "")
    service.captureSettled = false
    captureProcess.command = bounded(probeDeadlineSec, ["bash", "-lc", probeScript, "bash"])
    captureProcess.running = true
    captureWatchdog.restart()
    return true
  }

  property bool captureSettled: false

  function settleCapture(warning) {
    if (service.captureSettled) return
    service.captureSettled = true
    captureWatchdog.stop()
    if (warning) log("warn", warning)
    service.finishCapture()
  }

  Process {
    id: captureProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.probeResult = Model.parseProbeOutput(text)
    }
    onExited: service.settleCapture("")
  }

  Timer {
    id: captureWatchdog
    interval: (service.probeDeadlineSec + 3) * 1000
    repeat: false
    onTriggered: {
      if (captureProcess.running) captureProcess.running = false
      service.settleCapture("Capture probe did not finish in "
        + service.probeDeadlineSec + "s; captured what was already known")
    }
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
    if (parsed.disarmed > 0)
      log("warn", "Set " + parsed.disarmed + " imported trigger(s) back to asking; "
        + "an imported file does not get to run a mode on its own")
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

  // Placement is not a trigger and stays on whether or not triggers are.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || String(event.name) !== "openwindow") return
      service.handleWindowPlacement(event.data)
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
    notify([
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

  // The guard runs first and the FileViews are read once it clears them, so
  // there is nothing to reload here until then.
  Component.onCompleted: service.checkPaths()

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

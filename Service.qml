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
  readonly property string configPath: home + "/.config/omarchy/wsmodes.json"
  readonly property string statePath: home + "/.local/state/omarchy/wsmodes-state.json"
  // This plugin used to be called Omara. Modes written under that name are
  // still your modes, so the first load that finds nothing at the new path
  // looks here before deciding you have none.
  readonly property string legacyConfigPath: home + "/.config/omarchy/omara.json"

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
    if (level === "warn") console.warn("[wsmodes]", message)
    else console.log("[wsmodes]", message)
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
  // These commands are what enforce the guard, the caps and the supervision,
  // so they are resolved from a fixed location rather than through the user's
  // PATH. An entry earlier in PATH would otherwise be able to replace the very
  // checks that make everything below them meaningful.
  readonly property string binTimeout: "/usr/bin/timeout"
  readonly property string binBash: "/usr/bin/bash"

  // Prefix for every helper script, for the same reason: the utilities inside
  // a script are resolved through PATH too.
  readonly property string safePath: "PATH=/usr/bin:/bin\nexport PATH\n"

  function bounded(seconds, argv) {
    return [binTimeout, "-k", "2", String(seconds)].concat(argv)
  }

  // Actions are the other case, and they need the opposite default. Killing a
  // producer is free — all we wanted was its output. Killing omarchy-theme-set
  // half way through leaves a partly applied theme, which is worse than
  // waiting, so an action is not killed at the reporting deadline: we stop
  // waiting and say so, and it finishes on its own. The far backstop is only
  // there so a genuinely wedged process cannot live forever.
  readonly property int actionKillSec: 120

  function boundedAction(argv) {
    return [binTimeout, "-k", "5", String(actionKillSec)].concat(argv)
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
  property var actionQueue: []
  property int activeAction: 0

  // Bumped every time a plan is submitted. A verdict from an older generation
  // is still logged, but it does not get to announce itself as the mode you
  // are in — a later switch has already answered that.
  property int planGeneration: 0

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

      // Stop waiting. This is not the same as stopping the process, and the
      // owner has to stay alive either way: destroying it here would take the
      // running Process with it and terminate a theme half way through
      // applying — which is the thing the deadline is written to avoid.
      function report(code) {
        if (run.settled) return
        run.settled = true
        runDeadline.stop()
        service.settleRun(run.runId, code === 0, code === 0 ? ""
          : ((code === 124 || code === 137)
            ? run.label + " did not report back within " + service.actionDeadlineSec + "s"
            : run.label + " exited " + code))
      }

      // Teardown, explicitly: ask, then insist. Reaping is the kernel's job
      // once the process group is gone, and `timeout` holds the outer bound.
      function terminate() {
        if (!proc.running) return
        proc.signal(15)
        killDelay.start()
      }

      Timer {
        id: killDelay
        interval: 2000
        repeat: false
        onTriggered: if (proc.running) proc.signal(9)
      }

      Process {
        id: proc
        command: run.argv
        // The real exit, whenever it comes. Only now is it safe to tear the
        // owner down, and only now is the child actually reaped.
        onExited: function(exitCode) {
          run.report(exitCode)
          killDelay.stop()
          service.releaseRun(run.runId)
          run.destroy()
        }
      }

      // Second line behind `timeout`, for a child that is unkillable rather
      // than slow. Whatever is waiting on this run gets released either way.
      Timer {
        id: runDeadline
        interval: (service.actionDeadlineSec + 3) * 1000
        repeat: false
        running: true
        // Stop waiting, do not kill. The process keeps going and finishes its
        // work; we have simply stopped holding a verdict open for it. The
        // owner lives until the real exit, which the backstop guarantees.
        onTriggered: run.report(124)
      }
    }
  }

  // Returns a token an activation step can carry, so the step's own result is
  // amended once the process actually reports. A non-blocking run is one whose
  // failure is worth a log line but should not hold up the verdict.
  function runSupervised(argv, label, blocking) {
    var id = service.nextRunId++
    var name = String(label || (argv && argv[0]) || "command")
    var isBlocking = blocking !== false
    service.runRegistry[id] = {
      settled: false, ok: true, detail: "", blocking: isBlocking,
      label: name, argv: boundedAction(argv), obj: null, startedAt: 0,
      reported: false, exited: false
    }

    // State-changing actions run one at a time, in the order they were asked
    // for. Two theme changes in flight at once can land in either order, which
    // is how the desktop ends up showing something other than the mode that
    // was reported. A notification changes nothing, so it does not queue.
    if (!isBlocking) {
      startRun(id)
      return id
    }
    service.actionQueue = service.actionQueue.concat([id])
    pumpActions()
    return id
  }

  function pumpActions() {
    if (service.activeAction !== 0) return
    if (service.actionQueue.length === 0) return
    var id = service.actionQueue[0]
    service.actionQueue = service.actionQueue.slice(1)
    service.activeAction = id
    startRun(id)
  }

  function startRun(id) {
    var rec = service.runRegistry[id]
    if (!rec) return
    var obj = supervisedRun.createObject(service, {
      runId: id, label: rec.label, argv: rec.argv
    })
    if (!obj) {
      settleRun(id, false, rec.label + " could not be started")
      releaseRun(id)
      return
    }
    rec.obj = obj
    rec.startedAt = Date.now()
    obj.start()
  }

  // The process actually exited. The next queued action may only start now:
  // releasing on the reporting deadline instead would put two of them in
  // flight, which is the overlap the queue exists to prevent.
  function releaseRun(id) {
    var rec = service.runRegistry[id]
    if (rec) {
      rec.obj = null
      rec.exited = true
      if (rec.reported) delete service.runRegistry[id]
    }
    if (service.activeAction !== id) return
    service.activeAction = 0
    pumpActions()
  }

  // A process that outlives even its backstop would stall the queue behind it.
  // The slot is only ever freed by a real exit, so a missing record here means
  // the run is genuinely gone rather than merely reported.
  function sweepActions() {
    if (service.activeAction === 0) return
    var rec = service.runRegistry[service.activeAction]
    if (!rec) {
      service.activeAction = 0
      pumpActions()
      return
    }
    if (Date.now() - rec.startedAt < (service.actionKillSec + 15) * 1000) return
    log("warn", rec.label + " outlived its backstop; terminating so the queue can move")
    if (rec.obj) rec.obj.terminate()
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
      // here. releaseRun still owns the entry until the process exits.
      if (!ok) log("warn", detail)
      rec.reported = true
      return
    }
    checkAwaiting()
  }

  // ---------------------------------------------------------- guarded files
  //
  // Quickshell's FileView takes a pathname, opens it, and reads to the end. It
  // has no descriptor-relative read, no O_NOFOLLOW, no non-blocking open and no
  // size ceiling, so a FIFO at wsmodes.json would block the shell on first read
  // and a symlink would redirect where modes are persisted.
  //
  // Checking the path and then handing the same name to FileView only narrows
  // that window; it does not close it. So the check and the read are one
  // operation instead. `dd iflag=nofollow,nonblock` carries the guarantees in
  // the open itself — a symlink is refused outright, a FIFO returns empty
  // rather than blocking, and count×bs is a hard byte ceiling — and the read
  // only happens beneath a directory verified to be ours and not writable by
  // anyone else.
  //
  // Writes are the same transaction from the other side: a fresh 0600 temp
  // file created under umask 077 in that verified directory, then renamed over
  // the target. Rename replaces a symlink or a FIFO rather than writing
  // through it, so the write cannot be redirected either.
  //
  // What this does not do is bind to an inode across the whole operation.
  // Reads and writes each carry their own guarantees, which is as far as the
  // available primitives reach.

  readonly property int fileMaxBytes: 4194304
  readonly property int fileDeadlineSec: 5

  readonly property string dirCheck:
    'uid=$(id -u)\n' +
    'dir=${target%/*}\n' +
    'dinfo=$(stat -c \'%F|%u|%a\' -- "$dir" 2>/dev/null) || fail "$dir cannot be read"\n' +
    'dtype=${dinfo%%|*}; drest=${dinfo#*|}\n' +
    'downer=${drest%%|*}; dmode=${drest##*|}\n' +
    '[ "$dtype" = directory ] || fail "$dir is not a directory (found: $dtype)"\n' +
    '[ "$downer" = "$uid" ] || fail "$dir is owned by uid $downer, not by you"\n' +
    'other=${dmode#"${dmode%?}"}\n' +
    'case $other in 2|3|6|7) fail "$dir is writable by any user (mode $dmode)" ;; esac\n'

  readonly property string readScript:
    safePath +
    'fail() { printf \'RESULT\\trefuse\\t%s\\n\' "$1"; exit 0; }\n' +
    'limit=$1\n' +
    'target=$2\n' +
    dirCheck +
    'if [ ! -e "$target" ]; then printf \'RESULT\\tabsent\\t\\n\'; exit 0; fi\n' +
    'tinfo=$(stat -c \'%F|%u|%s\' -- "$target" 2>/dev/null) || fail "it cannot be read"\n' +
    'ttype=${tinfo%%|*}; trest=${tinfo#*|}\n' +
    'towner=${trest%%|*}; tsize=${trest##*|}\n' +
    'case $ttype in\n' +
    '  "regular file" | "regular empty file") ;;\n' +
    '  *) fail "it is not a regular file (found: $ttype)" ;;\n' +
    'esac\n' +
    '[ "$towner" = "$uid" ] || fail "it is owned by uid $towner, not by you"\n' +
    '[ "$tsize" -le "$limit" ] || fail "it is $tsize bytes, past the $limit byte ceiling"\n' +
    // The open itself is where the guarantees live: nofollow refuses a symlink,
    // nonblock refuses to wait on a FIFO, count x bs is the ceiling.
    'body=$(dd if="$target" iflag=nofollow,nonblock bs=4096 count=$((limit / 4096)) 2>/dev/null)' +
    ' || fail "it could not be opened without following a link"\n' +
    'printf \'RESULT\\tok\\t\\n\'\n' +
    'printf \'%s\' "$body"\n'

  readonly property string writeScript:
    safePath +
    'fail() { printf \'RESULT\\trefuse\\t%s\\n\' "$1"; exit 0; }\n' +
    'target=$1\n' +
    dirCheck +
    'umask 077\n' +
    'tmp=$(mktemp "$dir/.wsmodes.XXXXXX") || fail "no temporary file could be made in $dir"\n' +
    'cat > "$tmp" || { rm -f "$tmp"; fail "the write did not complete"; }\n' +
    'mv -f -- "$tmp" "$target" || { rm -f "$tmp"; fail "the file could not be replaced"; }\n' +
    'printf \'RESULT\\tok\\t\\n\'\n'

  Component {
    id: guardedIo

    Item {
      id: io
      property var argv: []
      property string payload: ""
      property var handler: null
      property bool done: false

      function begin() {
        proc.running = true
        if (io.payload === "") return
        proc.write(io.payload)
        proc.stdinEnabled = false
      }

      function settle(verdict, detail, content) {
        if (io.done) return
        io.done = true
        deadline.stop()
        try {
          if (typeof io.handler === "function") io.handler(verdict, detail, content)
        } catch (e) {
          service.log("warn", "File handler failed: " + (e && e.message ? e.message : "error"))
        }
        io.destroy()
      }

      Process {
        id: proc
        command: io.argv
        stdinEnabled: io.payload !== ""
        stdout: StdioCollector { waitForEnd: true }
        onExited: function(exitCode) {
          var parsed = Model.parseFileResult(String(proc.stdout.text || ""), service.fileMaxBytes)
          if (exitCode !== 0 && parsed.verdict === "")
            io.settle("refuse", "the check did not complete (exit " + exitCode + ")", "")
          else io.settle(parsed.verdict || "refuse", parsed.detail, parsed.content)
        }
      }

      Timer {
        id: deadline
        interval: (service.fileDeadlineSec + 3) * 1000
        repeat: false
        running: true
        onTriggered: {
          if (proc.running) proc.running = false
          io.settle("refuse", "the check did not finish in " + service.fileDeadlineSec + "s", "")
        }
      }
    }
  }

  // An incomplete check refuses. Failing open here would mean the guard could
  // be removed simply by making it fail, which is not a guard.
  function readGuarded(path, handler) {
    var obj = guardedIo.createObject(service, {
      argv: bounded(fileDeadlineSec,
        [binBash, "-c", readScript, "bash", String(fileMaxBytes), String(path)]),
      handler: handler
    })
    if (!obj) handler("refuse", "no reader could be started", "")
    else obj.begin()
  }

  // Publications are serialised per target. Two renames racing can land in
  // either order, which would let an older save overwrite a newer one on disk.
  // Queued content is also coalesced: if a newer model arrives while a write is
  // in flight, the older one it superseded is never published at all.
  property var writeQueue: ({})

  function writeGuarded(path, text, handler) {
    var key = String(path)
    var q = service.writeQueue[key]
    if (!q) {
      q = { running: false, pending: null }
      service.writeQueue[key] = q
    }
    if (q.pending && typeof q.pending.handler === "function")
      q.pending.handler("superseded", "a newer version was queued first", "")
    q.pending = { text: String(text), handler: handler }
    pumpWrites(key)
  }

  function pumpWrites(key) {
    var q = service.writeQueue[key]
    if (!q || q.running || !q.pending) return
    var job = q.pending
    q.pending = null
    q.running = true

    var obj = guardedIo.createObject(service, {
      argv: bounded(fileDeadlineSec, [binBash, "-c", writeScript, "bash", key]),
      payload: job.text,
      handler: function(verdict, detail) {
        q.running = false
        try {
          if (typeof job.handler === "function") job.handler(verdict, detail, "")
        } finally {
          service.pumpWrites(key)
        }
      }
    })
    if (!obj) {
      q.running = false
      if (typeof job.handler === "function") job.handler("refuse", "no writer could be started", "")
      return
    }
    obj.begin()
  }

  // ------------------------------------------------------------ persistence

  property string configRefusal: ""
  property bool configReadOnly: false

  function applyConfig(next, reason) {
    var normalized = Model.normalizeConfig(next)
    service.config = normalized.config
    for (var i = 0; i < normalized.warnings.length; i++) log("warn", normalized.warnings[i])
    save()
    service.modesUpdated()
    if (reason) log("info", reason)
  }

  function save() {
    if (!configLoaded || service.configReadOnly) return
    var text = Model.serializeConfig(service.config)
    if (text === lastWrittenText) return
    lastWrittenText = text
    writeGuarded(service.configPath, text, function(verdict, detail) {
      if (verdict === "ok" || verdict === "superseded") return
      service.lastWrittenText = ""
      log("warn", "Could not write wsmodes.json: " + detail)
    })
  }

  function loadConfigFromDisk() {
    readGuarded(service.configPath, function(verdict, detail, content) {
      if (verdict === "refuse") {
        service.configReadOnly = true
        refuseConfig(detail)
        if (!service.configLoaded) {
          service.configLoaded = true
          service.modesUpdated()
        }
        return
      }
      service.configReadOnly = false
      service.configRefusal = ""
      var text = verdict === "absent" ? "" : content

      // Exactly once, and only on the first load: after you have deleted
      // every mode, a file left over from the old name must not bring them
      // back on the next poll.
      if (verdict === "absent" && !service.configLoaded && !service.legacyChecked) {
        service.legacyChecked = true
        service.adoptLegacyConfig()
        return
      }
      service.legacyChecked = true

      if (service.configLoaded && text === service.lastWrittenText) return
      service.lastWrittenText = text
      service.loadConfig(text)
    })
  }

  property bool legacyChecked: false

  // Read the old file and load it as if it had been found at the new path.
  // Nothing is moved or deleted: the next save writes wsmodes.json, and
  // omara.json is left exactly where it is, in case you want to go back.
  function adoptLegacyConfig() {
    readGuarded(service.legacyConfigPath, function(verdict, detail, content) {
      var text = verdict === "ok" ? String(content || "") : ""
      // Empty either way, so the next save is a real write rather than a
      // comparison against text that was never on disk under this name.
      service.lastWrittenText = ""
      if (text.trim() === "") {
        service.loadConfig("")
        return
      }
      log("info", "Adopted your modes from " + service.legacyConfigPath
        + "; from now on they are saved to " + service.configPath)
      service.loadConfig(text)
      service.save()
    })
  }

  function loadConfig(raw) {
    var parsed = Model.parseConfig(raw)
    service.config = parsed.config
    for (var i = 0; i < parsed.warnings.length; i++) log("warn", parsed.warnings[i])
    if (parsed.recovered) service.backupBrokenConfig(raw)
    service.configLoaded = true
    service.modesUpdated()
  }

  // Refusing is not destructive: the path is left exactly as it was, and
  // configReadOnly is what stops anything being written back through it.
  function refuseConfig(detail) {
    var reason = String(detail || "it did not pass the file check")
    if (service.configRefusal === reason) return
    service.configRefusal = reason
    log("warn", "Refusing to read or write wsmodes.json: " + reason)
    notify([
      "omarchy-notification-send", "--app-name", "Workspace Modes", "-u", "critical", "Workspace Modes",
      "wsmodes.json was not used because " + reason
        + ". Workspace Modes started with no modes and will not write to that path. Nothing was changed or deleted."
    ])
  }

  // The recovery copy is the bytes that were actually read, not a second open
  // of the same name. Copying by path re-resolved it, so what landed in the
  // backup was whatever the name pointed at by then rather than what failed to
  // parse — and a detached copy nobody was watching did the writing.
  function backupBrokenConfig(raw) {
    var backup = service.configPath + ".corrupt"
    writeGuarded(backup, String(raw === undefined || raw === null ? "" : raw), function(verdict, detail) {
      if (verdict === "ok") log("warn", "Saved the unreadable wsmodes.json as " + backup)
      else log("warn", "Could not save " + backup + ": " + detail)
    })
    notify([
      "omarchy-notification-send", "--app-name", "Workspace Modes", "-u", "normal",
      "Workspace Modes", "wsmodes.json could not be read. A copy was saved as wsmodes.json.corrupt."
    ])
  }

  // Polling rather than watching: a file watcher dies when the file is
  // replaced by rename, which is exactly how this file is written.
  Timer {
    id: reconcileTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: service.loadConfigFromDisk()
  }

  function loadStateFromDisk() {
    readGuarded(service.statePath, function(verdict, detail, content) {
      if (verdict === "refuse") {
        service.stateReadOnly = true
        log("warn", "Not reading or writing wsmodes-state.json: " + detail)
        return
      }
      service.stateReadOnly = false
      service.loadState(verdict === "absent" ? "" : content)
    })
  }

  property bool stateReadOnly: false

  function loadState(raw) {
    try {
      var parsed = JSON.parse(String(raw || "").trim() || "{}")
      service.previousState = Model.isPlainObject(parsed) ? parsed : ({})
    } catch (e) {
      service.previousState = ({})
    }
  }

  function saveState() {
    if (service.stateReadOnly) return
    writeGuarded(service.statePath, JSON.stringify(service.previousState, null, 2) + "\n",
      function(verdict, detail) {
        if (verdict !== "ok" && verdict !== "superseded")
          log("warn", "Could not write wsmodes-state.json: " + detail)
      })
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

  // A folder is stored `~`-relative so it survives a machine change, and is
  // only made absolute here, at the point something has to chdir into it.
  function launchDirectory(directory) {
    return Model.expandHome(String(directory || ""), service.home)
  }

  // One argv, one folder, one shell line. Quoting every word means a path with
  // a space in it is one argument, and nothing in a file name is ever read as
  // shell syntax.
  function shellLineFor(argv, directory) {
    var quoted = []
    for (var i = 0; i < argv.length; i++) quoted.push(Util.shellQuote(argv[i]))
    var line = quoted.join(" ")
    return directory === "" ? line : "cd -- " + Util.shellQuote(directory) + " && " + line
  }

  // Detached on purpose: `exec "$@"` becomes the application, so supervising
  // this would parent it to the shell and kill it on the next shell restart.
  // Whether it could start at all is answered ahead of time by the probe,
  // which is why runPlan skips a command that is not installed.
  function execDetachedIn(argv, directory) {
    // The folder rides in as an argument, never spliced into the script: the
    // two constants below are the whole of what a shell is asked to parse.
    var script = directory === "" ? 'exec "$@"' : 'cd -- "$1" || exit 1; shift; exec "$@"'
    var extra = directory === "" ? [] : [directory]
    Quickshell.execDetached(["bash", "-lc", script, "bash"].concat(extra, argv))
  }

  function launchDesktopEntry(desktopId, args, directory, workspace) {
    var entry = desktopEntry(desktopId)
    if (!entry)
      return { ok: false, detail: "\"" + desktopId + "\" is not installed; skipped" }
    var name = String(entry.name || desktopId)
    if (workspace !== null && workspace !== undefined && Model.workspaceRef(workspace) === "")
      return { ok: false, detail: "\"" + String(workspace) + "\" is not a workspace Hyprland can name; skipped" }
    var placed = workspace !== null && workspace !== undefined
    var where = placed ? " on workspace " + workspace : ""

    var extra = Model.parseArgv(String(args || ""))
    if (extra.unterminated)
      return { ok: false, detail: "Unbalanced quote in \"" + String(args) + "\"" }
    var dir = launchDirectory(directory)

    // Arguments and a folder are things a .desktop file cannot be told, so
    // once a mode asks for either we run the entry's own Exec line instead of
    // handing the id to gtk-launch. With neither, nothing changes: the launch
    // still goes through the app daemon and lands in its own systemd scope.
    if (extra.argv.length > 0 || dir !== "") {
      var base = entryArgv(entry)
      if (base.length === 0)
        return { ok: false, detail: "\"" + desktopId + "\" has no command to run; skipped" }
      var argv = base.concat(extra.argv)
      var suffix = extra.argv.length > 0 ? " " + extra.argv.join(" ") : ""
      if (dir !== "") suffix += " (in " + Model.prettyDirectory(directory) + ")"
      if (placed) {
        expectPlacement(Model.placementKeys(desktopId, argv[0], entry.startupClass), workspace)
        launchOnWorkspace(workspace, shellLineFor(argv, dir))
      } else {
        execDetachedIn(argv, dir)
      }
      return { ok: true, detail: "Launched " + name + suffix + where }
    }

    if (placed) {
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

  // A desktop entry's Exec line, as words. `command` is already split with the
  // field codes resolved; execString is the raw line and only a fallback.
  function entryArgv(entry) {
    var out = []
    var list = entry && entry.command ? entry.command : []
    for (var i = 0; i < list.length; i++) {
      var word = String(list[i] || "").trim()
      // A field code left unresolved stands for a file we were not given.
      if (word === "" || /^%[a-zA-Z]$/.test(word)) continue
      out.push(word)
    }
    if (out.length > 0) return out
    var parsed = Model.parseArgv(entry && entry.execString ? String(entry.execString) : "")
    return parsed.unterminated ? [] : parsed.argv
  }

  function launchApplication(command, args, directory, workspace) {
    var parsed = Model.parseArgv(String(command || ""))
    if (parsed.argv.length === 0)
      return { ok: false, detail: "Empty application command" }
    if (parsed.unterminated)
      return { ok: false, detail: "Unbalanced quote in \"" + command + "\"" }
    var extra = Model.parseArgv(String(args || ""))
    if (extra.unterminated)
      return { ok: false, detail: "Unbalanced quote in \"" + String(args) + "\"" }

    var argv = parsed.argv.concat(extra.argv)
    var dir = launchDirectory(directory)
    var suffix = extra.argv.length > 0 ? " " + extra.argv.join(" ") : ""
    if (dir !== "") suffix += " (in " + Model.prettyDirectory(directory) + ")"

    if (workspace !== null && workspace !== undefined) {
      if (Model.workspaceRef(workspace) === "")
        return { ok: false, detail: "\"" + String(workspace) + "\" is not a workspace Hyprland can name; skipped" }
      expectPlacement(Model.placementKeys("", argv[0], ""), workspace)
      launchOnWorkspace(workspace, shellLineFor(argv, dir))
      return { ok: true, detail: "Launched " + argv[0] + suffix + " on workspace " + workspace }
    }

    execDetachedIn(argv, dir)
    return { ok: true, detail: "Launched " + argv[0] + suffix }
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
          ? launchDesktopEntry(step.desktopId, step.args, step.directory, step.workspace)
          : launchApplication(step.value, step.args, step.directory, step.workspace)
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
      [binBash, "-lc", probeScript, "bash"].concat(binaries.slice(0, probeMaxBinaries)))
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
  //
  // This one keeps the login shell, deliberately and narrowly: `command -v` is
  // asking whether *your* environment can start a configured application, so it
  // has to use your PATH. Everything else in the script uses the pinned one.
  readonly property string probeScript:
    'userpath=$PATH\n' +
    safePath +
    'ws=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null | head -c 4096)\n' +
    'printf \'WALLPAPER\\t%s\\n\' "$ws"\n' +
    'th=$(head -c 256 "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null | head -n 1)\n' +
    'printf \'THEME\\t%s\\n\' "$th"\n' +
    'n=0\n' +
    'for bin in "$@"; do\n' +
    '  n=$((n + 1)); [ "$n" -gt 256 ] && break\n' +
    '  b=$(printf %s "$bin" | head -c 256)\n' +
    '  if PATH=$userpath command -v -- "$b" >/dev/null 2>&1; then printf \'APP\\tok\\t%s\\n\' "$b"\n' +
    '  else printf \'APP\\tmissing\\t%s\\n\' "$b"; fi\n' +
    'done\n'

  // Capture asks the same two questions about the desktop, and one more about
  // every window on it: where its process is sitting, and what it was actually
  // started with. Both come from /proc, which only answers for your own
  // processes — a window someone else owns simply produces no PROC line.
  //
  // argv is joined on \037 rather than a space because an argument is allowed
  // to contain a space; tabs and newlines are dropped so one process is always
  // one line.
  readonly property int captureMaxProcesses: 128
  readonly property string captureScript:
    safePath +
    'ws=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null | head -c 4096)\n' +
    'printf \'WALLPAPER\\t%s\\n\' "$ws"\n' +
    'th=$(head -c 256 "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null | head -n 1)\n' +
    'printf \'THEME\\t%s\\n\' "$th"\n' +
    'n=0\n' +
    'for pid in "$@"; do\n' +
    '  n=$((n + 1)); [ "$n" -gt 128 ] && break\n' +
    '  case $pid in \'\'|*[!0-9]*) continue;; esac\n' +
    '  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null | head -c 4096 | tr -d \'\\011\\012\')\n' +
    '  args=$(head -c 8192 "/proc/$pid/cmdline" 2>/dev/null | tr -d \'\\011\\012\' | tr \'\\000\' \'\\037\')\n' +
    '  printf \'PROC\\t%s\\t%s\\t%s\\n\' "$pid" "$cwd" "$args"\n' +
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
    var generation = ++service.planGeneration
    service.activating = false
    service.pendingActivation = null

    // An activation must still not announce success while the programs it
    // needed are failing, so the summary, the notification and the finished
    // signal all wait for what actually happened.
    awaitRuns(results, function(outcome) {
      var summary = Model.summarize(ctx.name, outcome)
      var current = generation === service.planGeneration
      log(summary.warnings > 0 ? "warn" : "info",
        "Activated " + ctx.name + (summary.warnings > 0 ? " with " + summary.warnings + " warning(s)" : "")
          + (current ? "" : " (superseded by a later switch)"))
      // A stale plan does not get to announce itself as the current mode.
      if (!current) return
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
  }

  function finishJob(job) {
    // A step carrying a token was not logged when it ran. This is where it
    // gets its one line, and the line says what actually happened.
    var results = job.results
    for (var i = 0; i < results.length; i++) {
      var id = results[i] ? results[i].run : 0
      if (!id) continue
      // Reporting is not the end of the run. The record is the queue's
      // lifecycle slot as well as the verdict, so it is only dropped once the
      // process has actually exited *and* its verdict has been read —
      // whichever happens second does the deleting.
      var rec = service.runRegistry[id]
      if (rec) {
        rec.reported = true
        if (rec.exited) delete service.runRegistry[id]
      }
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
    running: service.awaitJobs.length > 0 || service.activeAction !== 0
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
      service.sweepActions()
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
    var generation = ++service.planGeneration
    awaitRuns(results, function() {
      var current = generation === service.planGeneration
      log("info", (ctx ? "Deactivated " + ctx.name : "No mode was active")
        + (current ? "" : " (superseded by a later switch)"))
      if (!current) return
      if (!silent && config.behavior.showNotifications !== false)
        notify(["omarchy-notification-send", "--app-name", "Workspace Modes", "Workspace Modes", "No mode. " + name + " turned off."])
      service.activationFinished("", 0)
    })
    return true
  }

  function notifySummary(ctx, summary) {
    if (config.behavior.showNotifications === false) return
    var argv = ["omarchy-notification-send", "--app-name", "Workspace Modes"]
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
      // The pid is what lets capture ask /proc what this window is actually
      // running and where from. A window that does not report one still
      // captures, just without those two answers.
      var pid = ipc && ipc.pid ? String(ipc.pid) : ""
      var entry = entryForWindowClass(cls)
      out.push(entry
        ? { desktopId: String(entry.id), workspace: ws, title: title, pid: pid }
        : { command: cls.toLowerCase(), workspace: ws, title: title, pid: pid })
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
      service.log("warn", "Workspace Modes switch dialog failed to load; see the shell log for the QML error")
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
    safePath +
    'find -L "$OMARCHY_PATH/themes" "$HOME/.config/omarchy/themes" ' +
    '-mindepth 1 -maxdepth 1 -type d -printf \'%f\\n\' 2>/dev/null ' +
    '| head -n 512 | head -c 65536 | sort -u\n'

  function refreshThemes() {
    if (themeProcess.running) return
    themeProcess.command = bounded(themeDeadlineSec, [binBash, "-c", themeScript])
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
  property var captureWindows: []

  // Wallpaper, theme, and every window's command line live outside this
  // process, so capture waits on one subprocess for all of them. Everything
  // else is already in memory.
  //
  // The window list is taken now rather than when the probe returns: the pids
  // asked about have to be the pids answered for, and a window that closes in
  // between would otherwise be captured with another process's command line.
  function captureCurrentSetup(name) {
    if (captureProcess.running) return false
    service.captureName = String(name || "")
    service.captureWindows = openWindows()
    service.captureSettled = false

    var pids = []
    for (var i = 0; i < service.captureWindows.length && pids.length < captureMaxProcesses; i++) {
      var pid = service.captureWindows[i].pid
      if (pid && pids.indexOf(pid) === -1) pids.push(pid)
    }

    captureProcess.command = bounded(probeDeadlineSec,
      [binBash, "-lc", captureScript, "bash"].concat(pids))
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

  // Fold what /proc said about each window's process back into the window it
  // belongs to. A pid the probe could not read — another user's, or one that
  // exited mid-capture — simply contributes nothing.
  function capturedWindows() {
    var processes = service.probeResult.processes || ({})
    var out = []
    for (var i = 0; i < service.captureWindows.length; i++) {
      var w = service.captureWindows[i]
      var proc = w.pid ? processes[w.pid] : null
      out.push({
        desktopId: w.desktopId,
        command: w.command,
        workspace: w.workspace,
        title: w.title,
        args: proc ? Model.captureArguments(proc.argv, service.home) : "",
        directory: proc ? Model.captureDirectory(proc.cwd, service.home) : ""
      })
    }
    return out
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
      windows: capturedWindows()
    })
    service.captureName = ""
    service.captureWindows = []

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
      "--app-name", "Workspace Modes",
      "-u", "normal",
      "Switch to " + ctx.name + "?",
      decision.reason + ", click to switch",
      "--exec", "omarchy-shell", "-q", "wsmodes", "activateWindows", ctx.id, "keep"
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
      service.log("warn", "Workspace Modes editor failed to load; see the shell log for the QML error")
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
    target: "wsmodes"

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
      service.loadConfigFromDisk()
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

  // Both reads carry their own checks, so there is nothing to clear first.
  Component.onCompleted: {
    service.loadStateFromDisk()
    service.loadConfigFromDisk()
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

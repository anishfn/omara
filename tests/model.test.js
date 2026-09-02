const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const root = path.join(__dirname, "..")
const read = (f) => fs.readFileSync(path.join(root, f), "utf8")
const qmlFiles = fs.readdirSync(root).filter((f) => f.endsWith(".qml"))

// ------------------------------------------------------------------ parsing

// qmllint reports a parse error as exit 255 with nothing on stderr, so the
// exit code is the only signal. Worth its own test: `final` is a reserved word
// the QML parser rejects outright, and nothing else here would have caught it.
test("every QML file parses", { skip: !hasQmllint() }, () => {
  const { spawnSync } = require("node:child_process")
  for (const file of qmlFiles) {
    const run = spawnSync("qmllint", [file], { cwd: root })
    assert.equal(run.status, 0,
      `${file} does not parse (qmllint exit ${run.status})\n${run.stderr}`)
  }
})

// qmllint does not catch this one, and the shell reports it as
// "Property value set multiple times" and refuses to load the plugin.
test("no QML object declares the same handler twice", () => {
  for (const file of qmlFiles) {
    const src = read(file)
    for (const handler of ["Component.onCompleted", "Component.onDestruction"]) {
      const count = src.split(handler).length - 1
      assert.ok(count <= 1, `${file} declares ${handler} ${count} times`)
    }
  }
})

function hasQmllint() {
  const { spawnSync } = require("node:child_process")
  return spawnSync("qmllint", ["--version"]).status === 0
}

// ------------------------------------------------------------------ storage

test("a missing config is a first run, not an error", () => {
  const result = Model.parseConfig("")
  assert.equal(result.firstRun, true)
  assert.equal(result.recovered, false)
  assert.deepEqual(result.config.modes, [])
  assert.equal(result.config.activeMode, null)
})

test("a corrupt config yields working defaults and is flagged for backup, never silently rewritten", () => {
  const result = Model.parseConfig("{ this is not json")
  assert.equal(result.recovered, true)
  assert.equal(result.config.modes.length, 0)
  assert.match(result.warnings[0], /not valid JSON/)
})

test("missing and unknown fields are tolerated; unknown ones do not survive", () => {
  const { config, warnings } = Model.normalizeConfig({
    version: 1,
    modes: [{ id: "coding", name: "Coding", futureField: "???" }]
  })
  assert.equal(warnings.length, 0)
  assert.equal(config.modes[0].futureField, undefined)
  assert.deepEqual(config.modes[0].commands, { onActivate: [], onDeactivate: [] })
  assert.equal(config.modes[0].notifications.dnd, null)
})

test("a newer schema version is read rather than discarded, with a warning", () => {
  const { config, warnings } = Model.normalizeConfig({
    version: 99,
    modes: [{ id: "coding", name: "Coding" }]
  })
  assert.equal(config.modes.length, 1)
  assert.match(warnings.join(" "), /version 99/)
})

test("an active mode that no longer exists is cleared", () => {
  const { config, warnings } = Model.normalizeConfig({
    version: 1,
    activeMode: "gone",
    modes: [{ id: "coding", name: "Coding" }]
  })
  assert.equal(config.activeMode, null)
  assert.match(warnings.join(" "), /no longer exists/)
})

test("duplicate ids in a file are disambiguated instead of colliding", () => {
  const { config } = Model.normalizeConfig({
    version: 1,
    modes: [{ id: "coding", name: "A" }, { id: "coding", name: "B" }]
  })
  assert.deepEqual(Model.modeIds(config), ["coding", "coding-2"])
})

test("serialize round-trips through normalize", () => {
  const { config } = Model.normalizeConfig({ version: 1, modes: [{ id: "coding", name: "Coding" }] })
  assert.deepEqual(JSON.parse(Model.serializeConfig(config)), config)
})

// ---------------------------------------------------------------- tri-state

test("dnd distinguishes unchanged from off", () => {
  assert.equal(Model.asTristate(undefined), null)
  assert.equal(Model.asTristate("nonsense"), null)
  assert.equal(Model.asTristate(false), false)
  assert.equal(Model.asTristate("on"), true)
})

test("a mode that leaves dnd unchanged produces no dnd step", () => {
  const ctx = Model.normalizeMode({ id: "a", name: "A" }, [])
  assert.equal(Model.activationPlan(ctx, {}).length, 0)
})

test("a mode that turns dnd off still produces a dnd step", () => {
  const ctx = Model.normalizeMode({ id: "a", name: "A", notifications: { dnd: false } }, [])
  const plan = Model.activationPlan(ctx, {})
  assert.equal(plan.length, 1)
  assert.equal(plan[0].kind, "dnd")
  assert.equal(plan[0].value, false)
})

// ----------------------------------------------------------------- ids

test("ids are stable across renames", () => {
  let { config } = Model.normalizeConfig({ version: 1, modes: [{ id: "coding", name: "Coding" }] })
  const updated = Model.updateMode(config, "coding", { name: "Development" })
  assert.equal(updated.error, "")
  assert.equal(updated.mode.id, "coding")
  assert.equal(updated.mode.name, "Development")
})

test("a display name becomes a machine-safe id", () => {
  assert.equal(Model.slugify("Deep Work!"), "deep-work")
  assert.equal(Model.slugify("   "), "")
  assert.equal(Model.uniqueId("", []), "mode")
  assert.equal(Model.uniqueId("coding", ["coding", "coding-2"]), "coding-3")
})

test("updating a mode that does not exist is an error, not a silent create", () => {
  const config = Model.defaultConfig()
  const result = Model.updateMode(config, "nope", { name: "X" })
  assert.equal(result.mode, null)
  assert.match(result.error, /No mode with id/)
})

test("deleting the active mode clears the active pointer", () => {
  let config = Model.createMode(Model.defaultConfig(), { name: "Coding" }).config
  config = Model.setActiveMode(config, "coding")
  const result = Model.deleteMode(config, "coding")
  assert.equal(result.removed, true)
  assert.equal(result.config.activeMode, null)
})

test("setting an active mode that does not exist is refused", () => {
  assert.equal(Model.setActiveMode(Model.defaultConfig(), "ghost").activeMode, null)
})

// ------------------------------------------------------------ activation

test("the activation plan is ordered environment first, focus last", () => {
  const ctx = Model.normalizeMode({
    id: "gaming", name: "Gaming",
    notifications: { dnd: true },
    audio: { output: "sink" },
    appearance: { wallpaper: "/w.png", theme: "Tokyo Night" },
    workspaces: { target: 3 },
    applications: [{ command: "steam" }],
    commands: { onActivate: ["notify-send hi"] }
  }, [])
  assert.deepEqual(Model.activationPlan(ctx, {}).map(s => s.kind),
    ["dnd", "audio", "wallpaper", "theme", "applications", "commands", "workspace"])
})

test("settings-only activation never launches apps or runs commands", () => {
  const ctx = Model.normalizeMode({
    id: "gaming", name: "Gaming",
    notifications: { dnd: true },
    applications: [{ command: "steam" }],
    commands: { onActivate: ["rm -rf /tmp/x"] }
  }, [])
  assert.deepEqual(Model.activationPlan(ctx, { settingsOnly: true }).map(s => s.kind), ["dnd"])
})

test("an application is either a desktop entry or a raw command, never both", () => {
  assert.deepEqual(Model.normalizeApplication("ghostty"),
    { desktopId: "", command: "ghostty", workspace: null, note: "", enabled: true })
  assert.deepEqual(Model.normalizeApplication({ desktopId: "org.foo.Bar" }),
    { desktopId: "org.foo.Bar", command: "", workspace: null, note: "", enabled: true })
  assert.deepEqual(Model.normalizeApplication({ desktopId: "a", command: "b" }),
    { desktopId: "a", command: "", workspace: null, note: "", enabled: true })
  assert.equal(Model.normalizeApplication({}), null)
  assert.equal(Model.normalizeApplication({ command: "   " }), null)
})

test("applications can each name their own workspace", () => {
  assert.equal(Model.normalizeApplication({ command: "x", workspace: "2" }).workspace, 2)
  assert.equal(Model.normalizeApplication({ command: "x", workspace: "project" }).workspace, "project")
  assert.equal(Model.normalizeApplication({ command: "x", workspace: "" }).workspace, null)
  assert.equal(Model.normalizeApplication({ command: "x" }).workspace, null)
})

test("a mode can lay out several workspaces at once", () => {
  const ctx = Model.normalizeMode({
    id: "coding", name: "Coding",
    workspaces: { target: 1 },
    applications: [
      { desktopId: "term", workspace: 1 },
      { desktopId: "browser", workspace: 2 },
      { command: "slack" }
    ]
  }, [])
  const apps = Model.activationPlan(ctx, {}).filter(s => s.kind === "applications")
  assert.deepEqual(apps.map(s => s.workspace), [1, 2, null])
  assert.match(apps[1].label, /on workspace 2/)
})

test("placement rides as a Hyprland exec rule, and only when asked for", () => {
  assert.equal(Model.hyprlandExecRule(3, "alacritty"), "[workspace 3 silent] alacritty")
  assert.equal(Model.hyprlandExecRule("code", "x"), "[workspace code silent] x")
  assert.equal(Model.hyprlandExecRule(null, "alacritty"), "alacritty")
  assert.equal(Model.hyprlandExecRule(undefined, "alacritty"), "alacritty")
})

test("a workspace outside Hyprland's grammar is refused, not patched up", () => {
  assert.ok(Model.isWorkspaceRef(3))
  assert.ok(Model.isWorkspaceRef("+1"))
  assert.ok(Model.isWorkspaceRef("e+1"))
  assert.ok(Model.isWorkspaceRef("m-1"))
  assert.ok(Model.isWorkspaceRef("previous"))
  assert.ok(Model.isWorkspaceRef("special:magic"))
  assert.ok(Model.isWorkspaceRef("name:Deep Work"))
  assert.ok(Model.isWorkspaceRef("project"))

  assert.equal(Model.isWorkspaceRef('1] evil [x'), false)
  assert.equal(Model.isWorkspaceRef("1,address:0xdead"), false)
  assert.equal(Model.isWorkspaceRef('a"b\nc'), false)
  assert.equal(Model.isWorkspaceRef("1; exec evil"), false)
  assert.equal(Model.isWorkspaceRef("$(id)"), false)
  assert.equal(Model.isWorkspaceRef("x".repeat(64)), false)
  assert.equal(Model.isWorkspaceRef(""), false)

  assert.equal(Model.workspaceRef("2"), "2")
  assert.equal(Model.workspaceRef('1] evil [x'), "")
})

test("a workspace that cannot be dispatched never reaches a dispatch string", () => {
  assert.equal(Model.hyprlandExecRule('1] evil [x', "app"), "app")
  assert.equal(Model.hyprlandExecRule("1,address:0xdead", "app"), "app")
  assert.equal(Model.asWorkspace('1] evil [x'), null)
  assert.equal(Model.asWorkspace("special:magic"), "special:magic")
  assert.equal(Model.normalizeApplication({ command: "x", workspace: "1;evil" }).workspace, null)
})

test("a command cannot break out of the Lua string it is dispatched in", () => {
  assert.equal(Model.luaQuote('a"b'), '"a\\"b"')
  assert.equal(Model.luaQuote("a\\b"), '"a\\\\b"')
})

test("a desktop id written the way it is spelled on disk still resolves", () => {
  assert.equal(Model.normalizeApplication({ desktopId: "org.foo.Bar.desktop" }).desktopId, "org.foo.Bar")
})

test("a desktop-entry application produces a step the executor can route", () => {
  const ctx = Model.normalizeMode({
    id: "a", name: "A",
    applications: [{ desktopId: "org.foo.Bar" }, { command: "chromium --new-window" }]
  }, [])
  const steps = Model.activationPlan(ctx, {})
  assert.deepEqual(steps.map(s => s.desktopId), ["org.foo.Bar", ""])
  assert.deepEqual(steps.map(s => s.value), ["", "chromium --new-window"])
  assert.match(steps[0].label, /org\.foo\.Bar/)
})

test("an application always has something to call it, entry or command", () => {
  assert.equal(Model.applicationLabel({ desktopId: "org.foo.Bar", command: "" }), "org.foo.Bar")
  assert.equal(Model.applicationLabel({ desktopId: "", command: "ghostty -e top" }), "ghostty -e top")
  assert.equal(Model.applicationLabel(null), "")
})

test("disabled applications and the global launchApps switch are both honoured", () => {
  const ctx = Model.normalizeMode({
    id: "a", name: "A",
    applications: [{ command: "steam", enabled: false }, { command: "discord" }]
  }, [])
  assert.deepEqual(Model.activationPlan(ctx, {}).map(s => s.value), ["discord"])
  assert.deepEqual(Model.activationPlan(ctx, {}).map(s => s.desktopId), [""])
  assert.deepEqual(Model.activationPlan(ctx, {}).map(s => s.workspace), [null])
  assert.deepEqual(Model.activationPlan(ctx, { launchApps: false }), [])
})

test("a summary counts warnings rather than listing every action", () => {
  const summary = Model.summarize("Gaming", [{ ok: true }, { ok: false }, { ok: false }])
  assert.equal(summary.warnings, 2)
  assert.match(summary.body, /2 warnings/)
  assert.equal(Model.summarize("Coding", [{ ok: true }]).body, "")
})

// ------------------------------------------------------------- restoring

test("only values this plugin set are restored", () => {
  const snapshot = { dnd: false, appliedDnd: true, wallpaper: "/old.png", appliedWallpaper: "/new.png" }
  const steps = Model.restorePlan(snapshot, { dnd: true, wallpaper: "/new.png" })
  assert.deepEqual(steps.map(s => s.kind), ["dnd", "wallpaper"])
})

test("a value the user changed by hand since is left alone", () => {
  const snapshot = { dnd: false, appliedDnd: true }
  assert.deepEqual(Model.restorePlan(snapshot, { dnd: false }), [])
})

test("an empty snapshot restores nothing", () => {
  assert.deepEqual(Model.restorePlan({}, {}), [])
  assert.deepEqual(Model.restorePlan(null, {}), [])
})

// ------------------------------------------------------------------ argv

test("application commands tokenize like a shell, without being one", () => {
  assert.deepEqual(Model.parseArgv("ghostty").argv, ["ghostty"])
  assert.deepEqual(Model.parseArgv("chromium --app='https://a b'").argv, ["chromium", "--app=https://a b"])
  assert.deepEqual(Model.parseArgv("a  b\tc").argv, ["a", "b", "c"])
})

test("shell metacharacters in an application command stay literal data", () => {
  const parsed = Model.parseArgv("echo $(id); rm -rf /")
  assert.deepEqual(parsed.argv, ["echo", "$(id);", "rm", "-rf", "/"])
})

test("an unbalanced quote is reported rather than guessed at", () => {
  assert.equal(Model.parseArgv("chromium --app=\"unclosed").unterminated, true)
  assert.equal(Model.parseArgv("").argv.length, 0)
})

// --------------------------------------------------------- import/export

test("an export drops per-install state and carries a version", () => {
  const config = Model.createMode(Model.defaultConfig(), { name: "Coding" }).config
  const payload = Model.exportPayload(config, null)
  assert.equal(payload.version, Model.SCHEMA_VERSION)
  assert.equal(payload.modes[0].enabled, undefined)
})

test("exporting one mode exports only that one", () => {
  let config = Model.createMode(Model.defaultConfig(), { name: "Coding" }).config
  config = Model.createMode(config, { name: "Gaming" }).config
  assert.deepEqual(Model.exportPayload(config, ["gaming"]).modes.map(c => c.id), ["gaming"])
})

test("an import accepts an envelope, a bare array, or a single mode", () => {
  const one = { id: "coding", name: "Coding" }
  assert.equal(Model.parseImport(JSON.stringify(one)).modes.length, 1)
  assert.equal(Model.parseImport(JSON.stringify([one])).modes.length, 1)
  assert.equal(Model.parseImport(JSON.stringify({ modes: [one] })).modes.length, 1)
})

test("an unreadable import is refused with a reason", () => {
  assert.match(Model.parseImport("not json").error, /Not valid JSON/)
  assert.match(Model.parseImport("").error, /empty/)
  assert.match(Model.parseImport("[]").error, /No modes/)
})

test("a mode carrying commands is flagged so the import can warn", () => {
  assert.equal(Model.modeHasCommands({ commands: { onActivate: ["curl evil | sh"] } }), true)
  assert.equal(Model.modeHasCommands({ applications: [{ command: "steam" }] }), true)
  assert.equal(Model.modeHasCommands({ name: "Quiet" }), false)
})

test("an import preview names every line it would run, not just a count", () => {
  const preview = Model.importPreview(Model.parseImport(JSON.stringify({
    id: "evil",
    name: "Evil",
    applications: [{ command: "steam" }, { desktopId: "org.foo.Bar" }],
    commands: { onActivate: ["curl evil | sh"], onDeactivate: ["rm -rf ~"] }
  })).modes)

  assert.equal(preview.length, 1)
  assert.equal(preview[0].name, "Evil")
  assert.deepEqual(preview[0].runs,
    ["app  steam", "app  org.foo.Bar.desktop", "sh   curl evil | sh", "sh   rm -rf ~"])
})

test("an imported trigger arrives asking, never firing on its own", () => {
  const parsed = Model.parseImport(JSON.stringify({
    id: "evil",
    name: "Evil",
    commands: { onActivate: ["curl evil | sh"] },
    triggers: [
      { type: "application", value: "firefox", behavior: "auto" },
      { type: "application", value: "slack", behavior: "ask" },
      { type: "application", value: "steam" }
    ]
  }))

  // The blank one counts too: "default" follows the global setting, which is
  // "switch without asking" on a machine that turned confirmation off.
  assert.equal(parsed.disarmed, 2)
  assert.deepEqual(parsed.modes[0].triggers.map(t => t.behavior), ["ask", "ask", "ask"])

  const config = Model.importModes(Model.defaultConfig(), parsed.modes, "copy").config
  config.behavior.triggersEnabled = true
  config.behavior.confirmAutomaticSwitch = false
  const verdict = Model.evaluateTrigger(config, { windowClass: "firefox" }, { now: 1e9 })
  assert.equal(verdict.action, "ask")
})

test("importing a duplicate id defaults to keeping both", () => {
  const config = Model.createMode(Model.defaultConfig(), { name: "Coding" }).config
  const incoming = Model.parseImport(JSON.stringify({ id: "coding", name: "Coding", description: "theirs" })).modes
  const result = Model.importModes(config, incoming, "copy")
  assert.equal(result.config.modes.length, 2)
  assert.equal(result.config.modes[0].description, "")
  assert.match(result.config.modes[1].name, /copy/)
})

test("replace overwrites in place and keeps the id; skip keeps what exists", () => {
  const config = Model.createMode(Model.defaultConfig(), { name: "Coding" }).config
  const incoming = Model.parseImport(JSON.stringify({ id: "coding", name: "Theirs", description: "theirs" })).modes

  const replaced = Model.importModes(config, incoming, "replace")
  assert.equal(replaced.config.modes.length, 1)
  assert.equal(replaced.config.modes[0].id, "coding")
  assert.equal(replaced.config.modes[0].description, "theirs")

  const skipped = Model.importModes(config, incoming, "skip")
  assert.equal(skipped.config.modes.length, 1)
  assert.equal(skipped.config.modes[0].description, "")
  assert.deepEqual(skipped.skipped, ["coding"])
})

// ---------------------------------------------------------------- triggers

const triggerConfig = (overrides) => {
  const config = Model.normalizeConfig({
    version: 1,
    modes: [{
      id: "gaming", name: "Gaming",
      triggers: [{ type: "application", value: "steam", enabled: true, behavior: "ask" }]
    }]
  }).config
  config.behavior.triggersEnabled = true
  return Object.assign(config, overrides || {})
}

const openWindow = (cls) => Model.parseOpenWindowEvent("0x1,3," + cls + ",A title, with commas")

test("an openwindow event keeps a comma in the title intact", () => {
  const event = openWindow("steam")
  assert.equal(event.windowClass, "steam")
  assert.equal(event.title, "A title, with commas")
  assert.equal(Model.parseOpenWindowEvent("garbage"), null)
})

test("triggers are inert until switched on globally", () => {
  const config = triggerConfig()
  config.behavior.triggersEnabled = false
  assert.equal(Model.evaluateTrigger(config, openWindow("steam"), { now: 0 }).action, "ignore")
})

test("a matching window asks before switching", () => {
  const decision = Model.evaluateTrigger(triggerConfig(), openWindow("steam"), { now: 100000 })
  assert.equal(decision.action, "ask")
  assert.equal(decision.modeId, "gaming")
})

test("a class matches as a substring so steam_app_12345 still counts", () => {
  assert.equal(Model.evaluateTrigger(triggerConfig(), openWindow("steam_app_12345"), { now: 100000 }).action, "ask")
  assert.equal(Model.evaluateTrigger(triggerConfig(), openWindow("ghostty"), { now: 100000 }).action, "ignore")
})

test("a per-trigger behavior of auto overrides the global ask default", () => {
  const config = triggerConfig()
  config.modes[0].triggers[0].behavior = "auto"
  assert.equal(Model.evaluateTrigger(config, openWindow("steam"), { now: 100000 }).action, "switch")
})

test("an unset per-trigger behavior follows the global setting", () => {
  const config = triggerConfig()
  config.modes[0].triggers[0].behavior = ""
  config.behavior.confirmAutomaticSwitch = false
  assert.equal(Model.evaluateTrigger(config, openWindow("steam"), { now: 100000 }).action, "switch")
})

test("the mode that is already active never re-triggers itself", () => {
  const config = triggerConfig()
  config.activeMode = "gaming"
  assert.equal(Model.evaluateTrigger(config, openWindow("steam"), { now: 100000 }).action, "ignore")
})

test("a window opened by our own activation cannot start a switching loop", () => {
  const config = triggerConfig()
  const decision = Model.evaluateTrigger(config, openWindow("steam"), {
    now: 1000,
    lastActivationAt: 1000 - (Model.TRIGGER_COOLDOWN_MS - 1)
  })
  assert.equal(decision.action, "ignore")
  assert.match(decision.reason, /cooldown/)
})

test("the cooldown expires so a later launch does trigger", () => {
  const config = triggerConfig()
  const decision = Model.evaluateTrigger(config, openWindow("steam"), {
    now: 1000000,
    lastActivationAt: 1000000 - (Model.TRIGGER_COOLDOWN_MS + 1)
  })
  assert.equal(decision.action, "ask")
})

test("a disabled trigger and a disabled mode are both inert", () => {
  const disabledTrigger = triggerConfig()
  disabledTrigger.modes[0].triggers[0].enabled = false
  assert.equal(Model.evaluateTrigger(disabledTrigger, openWindow("steam"), { now: 1e6 }).action, "ignore")

  const disabledMode = triggerConfig()
  disabledMode.modes[0].enabled = false
  assert.equal(Model.evaluateTrigger(disabledMode, openWindow("steam"), { now: 1e6 }).action, "ignore")
})

test("reordering is clamped and leaves the list alone at the edges", () => {
  assert.deepEqual(Model.moveInList([1, 2, 3], 0, 1), [2, 1, 3])
  assert.deepEqual(Model.moveInList([1, 2, 3], 2, -1), [1, 3, 2])
  assert.deepEqual(Model.moveInList([1, 2, 3], 0, -1), [1, 2, 3])
  assert.deepEqual(Model.moveInList([1, 2, 3], 2, 1), [1, 2, 3])
  assert.deepEqual(Model.moveInList([1, 2, 3], 9, 1), [1, 2, 3])
  assert.deepEqual(Model.moveInList(null, 0, 1), [])
})

test("modes reorder by id, and report whether anything moved", () => {
  let config = Model.createMode(Model.defaultConfig(), { name: "A" }).config
  config = Model.createMode(config, { name: "B" }).config
  const down = Model.moveMode(config, "a", 1)
  assert.deepEqual(Model.modeIds(down.config), ["b", "a"])
  assert.equal(down.moved, true)
  assert.equal(Model.moveMode(config, "a", -1).moved, false)
  assert.equal(Model.moveMode(config, "ghost", 1).moved, false)
})

test("a capture note is display text and never affects the launch", () => {
  const app = Model.normalizeApplication({ desktopId: "firefox", note: "YouTube" })
  assert.equal(app.note, "YouTube")
  const plan = Model.activationPlan(
    Model.normalizeMode({ id: "a", name: "A", applications: [app] }, []), {})
  assert.equal(plan[0].desktopId, "firefox")
  assert.equal(plan[0].value, "")
  assert.equal(plan[0].note, undefined)
})

test("a window title rides through capture as the note", () => {
  const captured = Model.captureMode({
    windows: [
      { desktopId: "firefox", workspace: 1, title: "GitHub" },
      { desktopId: "firefox", workspace: 2, title: "YouTube" }
    ]
  })
  assert.deepEqual(captured.applications.map(a => a.note), ["GitHub", "YouTube"])
})

// ----------------------------------------------------------------- capture

test("a capture becomes a mode, sorted by workspace", () => {
  const captured = Model.captureMode({
    name: "Now",
    workspace: 2,
    dnd: false,
    audioOutput: "headset",
    wallpaper: "/w.png",
    theme: "Tokyo Night",
    windows: [
      { desktopId: "firefox", workspace: 2 },
      { desktopId: "term", workspace: 1 },
      { command: "oddball", workspace: null }
    ]
  })
  assert.equal(captured.name, "Now")
  assert.equal(captured.workspaces.target, 2)
  assert.equal(captured.notifications.dnd, false)
  assert.equal(captured.audio.output, "headset")
  assert.equal(captured.appearance.theme, "Tokyo Night")
  assert.deepEqual(captured.applications.map(a => a.workspace), [1, 2, null])
})

test("two windows of the same app on one workspace capture as one entry", () => {
  const captured = Model.captureMode({
    windows: [
      { desktopId: "term", workspace: 1 },
      { desktopId: "term", workspace: 1 },
      { desktopId: "term", workspace: 2 }
    ]
  })
  assert.deepEqual(captured.applications.map(a => a.workspace), [1, 2])
})

test("an empty desktop captures as an empty, still-valid mode", () => {
  const captured = Model.captureMode({})
  assert.equal(captured.name, "Current desktop")
  assert.deepEqual(captured.applications, [])
  assert.equal(captured.notifications.dnd, null)
  assert.equal(captured.workspaces.target, null)
  // Whatever comes out has to survive the same normalization as anything else.
  assert.ok(Model.normalizeMode(captured, []))
})

test("the shipped icon set is non-empty and free of tofu-prone entries", () => {
  const icons = JSON.parse(read("icons.json"))
  assert.ok(icons.length > 50, "expected a usable number of glyphs")
  for (const icon of icons) {
    assert.equal(typeof icon.g, "string")
    assert.ok(icon.g.length > 0 && icon.g.length <= 2, "glyph should be one character")
    assert.ok(String(icon.k).length > 0, "every glyph needs search keywords")
    const point = icon.g.codePointAt(0)
    const privateUse = (point >= 0xe000 && point <= 0xf8ff) || (point >= 0xf0000 && point <= 0xffffd)
    assert.ok(privateUse, "glyphs must be Nerd Font private-use, not arbitrary unicode")
  }
})

// --------------------------------------------------------------- templates

test("every template produces a valid mode", () => {
  for (const template of Model.templates()) {
    const ctx = Model.templateMode(template.key, [])
    assert.ok(ctx, template.key + " should produce a mode")
    assert.ok(Model.isValidId(ctx.id), template.key + " id should be machine safe")
    assert.equal(ctx.name, template.name)
  }
  assert.equal(Model.templateMode("nope", []), null)
})

test("no example modes ship: blank is the only template", () => {
  assert.deepEqual(Model.templates().map((t) => t.key), ["blank"])
  const source = read("EditorWindow.qml")
  for (const name of ["Coding", "Gaming", "Deep Work", "Presentation"])
    assert.ok(!source.includes('"' + name + '"'), name + " should not be offered as a template")
})

test("the bar mark is drawn in the theme's colour, not loaded as an image", () => {
  const mark = read("OmaraMark.qml")
  assert.match(mark, /import QtQuick\.Shapes/)
  assert.match(mark, /property color color: Color\.foreground/)
  const bar = read("BarWidget.qml")
  assert.match(bar, /OmaraMark \{/)
  assert.match(bar, /color: root\.foreground/)
  // A PNG in the bar cannot follow the theme; the logo belongs in the README.
  assert.ok(!/assets\/omara\.png/.test(bar), "the bar should not load the logo image")
})

test("nothing user-visible still says context", () => {
  for (const file of ["README.md", "manifest.json", "BarWidget.qml", "EditorWindow.qml",
    "ModeForm.qml", "ModeRow.qml", "Service.qml", "bin/omara"]) {
    const source = read(file)
    // The one allowed mention is reading the old config file by its old name.
    const hits = source.split("\n").filter((line) => /\bcontexts?\b/i.test(line))
    assert.deepEqual(hits, [], file + " still says context")
  }
})

// --------------------------------------------------------- window placement

test("the landing workspace is focused after the applications, not before", () => {
  const cfg = Model.parseConfig(JSON.stringify({
    version: 1,
    modes: [{ id: "c", name: "C", workspaces: { target: 1 },
      applications: [{ desktopId: "chromium", workspace: 2, enabled: true }],
      commands: { onActivate: ["echo hi"], onDeactivate: [] } }]
  })).config
  const kinds = Model.activationPlan(cfg.modes[0], { launchApps: true }).map((s) => s.kind)
  // A window that lands on the wrong workspace takes focus with it, so the
  // focus has to come last or the mode leaves you somewhere else.
  assert.equal(kinds[kinds.length - 1], "workspace")
  assert.ok(kinds.indexOf("applications") < kinds.indexOf("workspace"))
  assert.ok(kinds.indexOf("commands") < kinds.indexOf("workspace"))
})

test("a settings-only pass still focuses the landing workspace", () => {
  const cfg = Model.parseConfig(JSON.stringify({
    version: 1,
    modes: [{ id: "c", name: "C", workspaces: { target: 3 },
      applications: [{ desktopId: "chromium", workspace: 2, enabled: true }] }]
  })).config
  const plan = Model.activationPlan(cfg.modes[0], { settingsOnly: true })
  assert.deepEqual(plan.map((s) => s.kind), ["workspace"])
  assert.equal(plan[0].value, 3)
})

test("placement keys cover the reverse-dns and plain forms of an app", () => {
  assert.deepEqual(Model.placementKeys("chromium", "", ""), ["chromium"])
  assert.deepEqual(Model.placementKeys("com.mitchellh.ghostty", "", ""),
    ["com.mitchellh.ghostty", "ghostty"])
  // Two-letter noise would match half the desktop, so it is dropped.
  assert.deepEqual(Model.placementKeys("", "vi", ""), [])
})

test("a window is matched to the launch that was waiting for it", () => {
  const now = Date.now()
  const pending = [{ keys: Model.placementKeys("chromium", "", ""), workspace: "2", at: now }]
  assert.equal(Model.matchPlacement(pending, "chromium", now), 0)
  assert.equal(Model.matchPlacement(pending, "org.chromium.Chromium", now), 0)
  assert.equal(Model.matchPlacement(pending, "firefox", now), -1)
})

test("a launch that never produced a window stops being waited on", () => {
  const now = Date.now()
  const stale = now - Model.PLACEMENT_TTL_MS - 1
  const pending = [{ keys: ["chromium"], workspace: "2", at: stale }]
  assert.equal(Model.matchPlacement(pending, "chromium", now), -1)
  assert.deepEqual(Model.prunePlacements(pending, now), [])
  assert.equal(Model.prunePlacements([{ keys: ["chromium"], workspace: "2", at: now }], now).length, 1)
})

test("a stray window is moved without dragging focus with it", () => {
  const service = read("Service.qml")
  // follow = false is what keeps focus put; silent = true is not a real field.
  assert.match(service, /follow = false/)
  assert.match(service, /function handleWindowPlacement/)
  // Placement is not a trigger, so it must not be gated on triggersEnabled.
  const blocks = service.split("Connections {")
  const placement = blocks.find((b) => b.includes("handleWindowPlacement"))
  assert.ok(placement && !placement.includes("triggersEnabled"),
    "placement must work with triggers off")
})

// ------------------------------------------------------------------ glyphs

test("every icon in the UI comes from the shared glyph map", () => {
  const files = ["EditorWindow.qml", "ModeForm.qml", "ModeRow.qml", "BarWidget.qml",
    "AppPicker.qml", "IconPicker.qml", "ThemePicker.qml"]
  // The ad-hoc mix this replaced: wide plus, arrows, ticks, gears, triangles.
  const strays = /[\uff0b\u2913\u2715\u25b2\u25bc\u2713\u21bb\u25b8\u25be\u2699\u23fb]/
  for (const file of files) {
    const source = read(file)
    assert.ok(!strays.test(source), file + " still has a hand-picked symbol")
    if (/iconText:|Glyph\./.test(source))
      assert.match(source, /import "Model\.js" as Model/, file + " uses Glyph without importing Model")
  }
})

test("the glyph map is Nerd Font private-use only, one codepoint each", () => {
  const keys = Object.keys(Model.Glyph)
  assert.ok(keys.length > 10)
  const seen = new Set()
  for (const key of keys) {
    const glyph = Model.Glyph[key]
    assert.equal(Array.from(glyph).length, 1, key + " should be a single glyph")
    const cp = glyph.codePointAt(0)
    assert.ok(cp >= 0xe000 && cp <= 0xfffff, key + " should be private-use")
    assert.ok(!seen.has(cp), key + " duplicates another glyph")
    seen.add(cp)
  }
})

test("icons render at the icon size, never at a body size", () => {
  for (const file of ["ModeRow.qml", "ThemePicker.qml"]) {
    const source = read(file)
    const blocks = source.split(/\n\s*\n/).filter((b) => b.includes("Glyph."))
    for (const block of blocks)
      assert.ok(!/font\.pixelSize: Style\.font\.body/.test(block), file + " sizes a glyph as body text")
  }
})

// ----------------------------------------------------------------- themes

test("a theme is stored as the slug Omarchy writes, shown as a readable name", () => {
  assert.equal(Model.prettyThemeName("rose-pine-dark"), "Rose Pine Dark")
  assert.equal(Model.prettyThemeName("gruvbox"), "Gruvbox")
  assert.equal(Model.prettyThemeName(""), "")
})

test("the theme list drops blanks and duplicates, and sorts by name", () => {
  const list = Model.themeList(["tokyo-night", "", "gruvbox", "gruvbox", "  "])
  assert.deepEqual(list.map((t) => t.slug), ["gruvbox", "tokyo-night"])
  assert.equal(list[0].name, "Gruvbox")
})

test("theme search matches both the slug and the readable name", () => {
  const list = Model.themeList(["rose-pine-dark", "gruvbox"])
  assert.deepEqual(Model.filterThemes(list, "rose").map((t) => t.slug), ["rose-pine-dark"])
  assert.deepEqual(Model.filterThemes(list, "Pine Dark").map((t) => t.slug), ["rose-pine-dark"])
  assert.equal(Model.filterThemes(list, "").length, 2)
})

test("the theme picker reads the installed themes, it does not hardcode any", () => {
  const picker = read("ThemePicker.qml")
  assert.match(picker, /service\.themes/)
  assert.match(picker, /service\.refreshThemes\(\)/)
  assert.match(read("Service.qml"), /function refreshThemes\(\)/)
  // Both the shipped and the user theme directory, or user themes go missing.
  assert.match(read("Service.qml"), /OMARCHY_PATH\/themes.*\n.*|\$HOME\/\.config\/omarchy\/themes/)
  assert.match(read("ModeForm.qml"), /openThemePicker\(\)/)
})

// ------------------------------------------------------- switching windows

test("the window question is only asked when there is something to close", () => {
  assert.equal(Model.windowSwitchMode({}, undefined, true), "ask")
  assert.equal(Model.windowSwitchMode({}, undefined, false), "keep")
  assert.equal(Model.windowSwitchMode({ confirmWindowsOnSwitch: false }, undefined, true), "keep")
})

test("an explicit choice always wins over the setting", () => {
  for (const mode of ["close", "keep"]) {
    assert.equal(Model.windowSwitchMode({}, mode, true), mode)
    assert.equal(Model.windowSwitchMode({ confirmWindowsOnSwitch: false }, mode, true), mode)
  }
  assert.equal(Model.windowSwitchMode({}, "nonsense", true), "ask")
})

test("the prompt says how many windows are at stake", () => {
  assert.match(Model.switchPromptMessage("Coding", 1), /1 window is open/)
  assert.match(Model.switchPromptMessage("Coding", 4), /4 windows are open/)
  assert.match(Model.switchPromptMessage("Coding", 0), /"Coding"/)
})

test("windows are closed gracefully, never killed", () => {
  const service = read("Service.qml")
  assert.match(service, /hl\.dsp\.window\.close/)
  assert.ok(!/killwindow|forcekill|SIGKILL/.test(service), "no forced kill path")
  // The close happens after the snapshot, so a restore still has something to restore.
  assert.ok(service.indexOf("captureSnapshot(ctx)") < service.indexOf("pending.closeWindows"))
})

test("automatic and scripted switches never wait on the dialog", () => {
  const service = read("Service.qml")
  assert.match(service, /activateMode\(ctx\.id, \{ windows: "keep" \}\)/)
  assert.match(service, /function activateWindows\(id: string, mode: string\)/)
  assert.match(read("bin/omara"), /--close\) result=\$\(call activateWindows/)
})

test("settings expose the window question", () => {
  assert.equal(Model.defaultConfig().behavior.confirmWindowsOnSwitch, true)
  assert.match(read("EditorWindow.qml"), /key: "confirmWindowsOnSwitch"/)
})

test("nothing is created without being asked for: defaults ship zero modes", () => {
  assert.deepEqual(Model.defaultConfig().modes, [])
  assert.equal(Model.defaultConfig().behavior.triggersEnabled, false)
  assert.equal(Model.defaultConfig().behavior.restoreOnStart, false)
  assert.equal(Model.defaultConfig().behavior.confirmAutomaticSwitch, true)
})

// ------------------------------------------------------- shipped artifacts

test("the manifest matches what the shell's registry enforces", () => {
  const manifest = JSON.parse(read("manifest.json"))
  assert.equal(manifest.schemaVersion, 1)
  for (const field of ["id", "name", "version", "kinds", "entryPoints"])
    assert.ok(manifest[field] !== undefined, "missing " + field)
  assert.ok(!manifest.id.startsWith("omarchy."), "omarchy.* is a reserved namespace")
  assert.match(manifest.id, /^[A-Za-z0-9][A-Za-z0-9._-]*$/)
  assert.ok(["left", "center", "right"].includes(manifest.barWidget.defaultSection))
  for (const [kind, key] of [["bar-widget", "barWidget"], ["service", "service"]]) {
    assert.ok(manifest.kinds.includes(kind))
    const entry = manifest.entryPoints[key]
    assert.ok(entry && !entry.startsWith("/") && !entry.includes(".."), key + " must be a safe relative path")
    assert.ok(fs.existsSync(path.join(root, entry)), entry + " must exist")
  }
})

test("the bar widget exposes the three names the shell's summon routing calls", () => {
  const qml = read("BarWidget.qml")
  assert.match(qml, /property bool opened:/)
  assert.match(qml, /function open\(\)/)
  assert.match(qml, /function close\(\)/)
})

test("the service registers the IPC target the CLI talks to", () => {
  const qml = read("Service.qml")
  assert.match(qml, /target: "omara"/)
  for (const method of ["list", "current", "activate", "deactivate", "reload", "manage", "edit", "capture"])
    assert.match(qml, new RegExp("function " + method + "\\("), "missing IPC method " + method)
})

test("the editor stands down while an external chooser is up, and always comes back", () => {
  const qml = read("EditorWindow.qml")
  assert.match(qml, /visible: root\.opened && !root\.suspended/)
  assert.match(qml, /root\.suspended = true/)
  const finished = qml.slice(qml.indexOf("function chooserFinished"))
  assert.ok(finished.indexOf("root.resume()") < finished.indexOf("chooserError.trim()"),
    "chooserFinished must resume before it reports")
})

test("no route out of a half-finished edit skips the unsaved guard", () => {
  const qml = read("EditorWindow.qml")
  for (const route of ["requestClose", "requestSelect", "requestPane", "requestCreateMode"])
    assert.match(qml, new RegExp("function " + route + "\\("), "missing guarded route " + route)
  // The scrim, Escape, the close button and the sidebar all go through them.
  assert.doesNotMatch(qml, /onClicked: root\.close\(\)/)
  assert.match(qml, /onClicked: root\.requestClose\(\)/)
  assert.match(qml, /onClicked: root\.requestSelect\(modelData\.id\)/)
  // A field still under the caret has uncommitted text; guard() takes focus
  // back first so those changes are seen.
  const guard = qml.slice(qml.indexOf("function guard("))
  assert.ok(guard.indexOf("keyCatcher.forceActiveFocus()") < guard.indexOf("guardResolved"),
    "guard must commit the focused field before deciding")
})

test("the editor is reachable and operable from the keyboard", () => {
  const qml = read("EditorWindow.qml")
  assert.match(qml, /Keys\.onTabPressed/)
  assert.match(qml, /Qt\.Key_S/)
  assert.match(qml, /Qt\.Key_N/)
  assert.match(qml, /Qt\.Key_D/)
  assert.match(qml, /Qt\.AltModifier/)
  assert.match(read("ModeForm.qml"), /function focusFirstField/)
})

test("activating a mode is visible in the bar and cannot be double-fired", () => {
  const qml = read("BarWidget.qml")
  assert.match(qml, /service\.activating\) return/)
  assert.match(qml, /root\.activating/)
})

test("the app picker reads the shell's own application library", () => {
  const qml = read("AppPicker.qml")
  assert.match(qml, /appLibrary\.sortedEntries\(query\)/)
  assert.match(qml, /service\.appLibrary/)
  const service = read("Service.qml")
  assert.match(service, /shell\.appLibrary/)
  assert.match(service, /function launchDesktopEntry/)
})

test("application launches never hand a user string to a shell for parsing", () => {
  const qml = read("Service.qml")
  assert.match(qml, /exec "\$@"/)
  assert.doesNotMatch(qml, /execDetached\(\["bash", "-lc", parsed/)
})

test("probe output is bounded and cannot inherit from Object.prototype", () => {
  const probe = Model.parseProbeOutput(
    "WALLPAPER\t/home/a/bg.jpg\nTHEME\tgruvbox\nAPP\tmissing\tsteam\nAPP\tok\tghostty\n")
  assert.equal(probe.wallpaper, "/home/a/bg.jpg")
  assert.equal(probe.theme, "gruvbox")
  assert.equal(probe.missing.steam, true)
  assert.equal(probe.missing.ghostty, undefined)

  // The lookup is `missing[name] === true`, so a command sharing a name with
  // something on Object.prototype must not come back truthy.
  assert.equal(probe.missing.toString, undefined)
  assert.equal(probe.missing.constructor, undefined)
  assert.equal(probe.missing.hasOwnProperty, undefined)
  assert.equal(Object.getPrototypeOf(probe.missing), null)

  // A producer that ignores its own ceilings does not get to set ours.
  const flood = Array.from({ length: 5000 }, (_, i) => `APP\tmissing\tapp${i}`).join("\n")
  assert.ok(Object.keys(Model.parseProbeOutput(flood).missing).length <= 512)
  const huge = Model.parseProbeOutput("WALLPAPER\t" + "x".repeat(200000))
  assert.ok(huge.wallpaper.length <= 4096)

  // A closed record: three known keys, whatever the output says.
  assert.deepEqual(Object.keys(Model.parseProbeOutput("EVIL\tx\nWALLPAPER\ta")).sort(),
    ["missing", "theme", "wallpaper"])
})

test("the path guard's report is a closed set of verdicts", () => {
  const report = Model.parseGuardOutput(
    "GUARD\tconfig\tok\t\n" +
    "GUARD\tstate\trefuse\tit is not a regular file (found: fifo)\n")
  assert.equal(report.config.verdict, "ok")
  assert.equal(report.state.verdict, "refuse")
  assert.match(report.state.detail, /fifo/)
  assert.equal(Object.getPrototypeOf(report), null)

  // A verdict the guard cannot emit is dropped, not believed.
  assert.equal(Model.parseGuardOutput("GUARD\tconfig\tapproved\t").config, undefined)
  assert.equal(Model.parseGuardOutput("NOISE\tconfig\tok\t").config, undefined)
  assert.equal(Model.parseGuardOutput("GUARD\t\tok\t")[""], undefined)
})

test("a theme directory cannot vanish by sharing a name with a prototype key", () => {
  const themes = Model.themeList(["gruvbox", "constructor", "toString", "gruvbox"])
  assert.deepEqual(themes.map(t => t.slug).sort(), ["constructor", "gruvbox", "toString"])
  assert.ok(Model.themeList(Array.from({ length: 5000 }, (_, i) => "t" + i)).length <= 512)
})

test("the import pane shows the lines it would run before anything is imported", () => {
  const qml = read("EditorWindow.qml")
  assert.match(qml, /Model\.importPreview/)
  assert.match(qml, /modelData\.runs/)
  assert.match(qml, /root\.importDisarmed/)
  // Nothing is applied until a button is pressed.
  assert.match(qml, /function confirmImport/)
})

test("an activation reports what happened, not what it asked for", () => {
  const qml = read("Service.qml")
  // Steps carry a token and are logged at the verdict, never optimistically.
  assert.match(qml, /function runSupervised\(argv, label, blocking\)/)
  assert.match(qml, /if \(!result\.run\) log\(result\.ok \? "info" : "warn", result\.detail\)/)
  assert.match(qml, /function finishJob/)
  // activating comes down at the verdict, and every exit path releases it.
  assert.match(qml, /function abandonActivation/)
  assert.match(qml, /id: awaitSweep/)
  // Deactivation restores settings through the same functions, so it waits too.
  assert.match(qml, /function deactivateMode[\s\S]*?awaitRuns\(results, function/)
  for (const fn of ["setTheme", "setWallpaper", "setDnd"])
    assert.match(qml, new RegExp(`function ${fn}[\\s\\S]*?run: run`), `${fn} drops its verdict`)
})

test("only the processes that must outlive the shell stay detached", () => {
  const qml = read("Service.qml")
  const detached = qml.match(/Quickshell\.execDetached\(/g) || []
  // Exactly two: the raw application launch, where `exec "$@"` becomes the
  // application, and the documented onActivate/onDeactivate hook.
  assert.equal(detached.length, 2)
  assert.match(qml, /function runCommand[\s\S]*?Quickshell\.execDetached\(\["bash", "-lc", c\]\)/)
  // The export write is no longer a detached shell that logs success blind.
  const editor = read("EditorWindow.qml")
  assert.doesNotMatch(editor, /Quickshell\.execDetached/)
  assert.match(editor, /onSaveFailed/)
})

test("the config path is checked before FileView is ever pointed at it", () => {
  const qml = read("Service.qml")
  // FileView has no descriptor-relative read and no size ceiling, so the only
  // place a hostile path can be caught is before the path is handed over.
  assert.match(qml, /path: service\.configPathOk \? service\.configPath : ""/)
  assert.match(qml, /path: service\.statePathOk \? service\.statePath : ""/)
  assert.doesNotMatch(qml, /^\s*path: service\.configPath$/m)
  assert.match(qml, /function checkPaths/)
  // The recovery copy must not re-open the path it is recovering from.
  assert.doesNotMatch(qml, /cp -f --/)
  assert.match(qml, /function backupBrokenConfig\(raw\)/)
})

test("no subprocess the service reads from runs without a deadline", () => {
  const qml = read("Service.qml")
  assert.match(qml, /function bounded\(seconds, argv\)[\s\S]*?"timeout", "-k", "2"/)
  // Actions get a far backstop instead, because killing one mid-flight can
  // leave a half-applied theme; the reporting deadline just stops waiting.
  assert.match(qml, /function boundedAction\(argv\)[\s\S]*?actionKillSec/)
  assert.match(qml, /onTriggered: run\.finish\(124\)/)
  // Every Process command in the service goes through bounded().
  for (const id of ["guardProcess", "probeProcess", "captureProcess", "themeProcess"])
    assert.match(qml, new RegExp(id + "\\.command = bounded\\("), id + " is unbounded")
  assert.match(qml, /Component\.onDestruction/)
  // head -c on theme.name, not cat: a FIFO there must end at the deadline.
  assert.doesNotMatch(qml, /cat "\$HOME\/\.local\/state\/omarchy\/current\/theme\.name"/)
})

test("every workspace dispatch is built from a validated reference", () => {
  const qml = read("Service.qml")
  // No dispatch site may interpolate a raw workspace: each one goes through
  // Model.workspaceRef first, and the Lua path quotes what it gets.
  assert.match(qml, /function focusWorkspace[\s\S]*?Model\.workspaceRef\(target\)/)
  assert.match(qml, /function placeWindow[\s\S]*?Model\.workspaceRef\(workspace\)/)
  assert.doesNotMatch(qml, /"workspace " \+ workspace/)
  assert.doesNotMatch(qml, /movetoworkspacesilent " \+ workspace/)
  assert.doesNotMatch(qml, /id\.replace\(/)
})

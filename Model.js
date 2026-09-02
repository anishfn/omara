
// Pure logic: schema, activation plans, triggers, import/export.
// No Qt or Quickshell here, which is what lets tests/ run it under node.

// ---------------------------------------------------------------- constants

var SCHEMA_VERSION = 1

var ACTION_KINDS = ["dnd", "audio", "wallpaper", "theme", "workspace", "applications", "commands"]

var TRIGGER_TYPES = ["application"]
var TRIGGER_BEHAVIORS = ["ask", "auto"]

var TRIGGER_COOLDOWN_MS = 8000

// ---------------------------------------------------------------- utilities

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function clone(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value))
}

function asString(value, fallback) {
  if (value === undefined || value === null) return fallback === undefined ? "" : fallback
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return fallback === undefined ? "" : fallback
}

// null means "leave alone", which is not the same answer as false.
function asTristate(value) {
  if (value === true || value === false) return value
  if (typeof value === "string") {
    var v = value.toLowerCase()
    if (v === "true" || v === "on" || v === "yes" || v === "1") return true
    if (v === "false" || v === "off" || v === "no" || v === "0") return false
  }
  return null
}

function asBool(value, fallback) {
  var t = asTristate(value)
  return t === null ? fallback === true : t
}

// Hyprland's own workspace grammar: an id, a relative step, or a name. A
// workspace ends up interpolated into a dispatch string, so anything outside
// the grammar is refused here, at the edge, instead of being patched up later.
var WORKSPACE_STEP = /^[mre]?[+-]?~?\d{1,6}$/
var WORKSPACE_NAME = /^(?:(?:name|special):)?[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$/

function isWorkspaceRef(value) {
  if (typeof value === "number") return isFinite(value)
  var s = asString(value, "").trim()
  if (s === "" || s.length > 40) return false
  return WORKSPACE_STEP.test(s) || WORKSPACE_NAME.test(s)
}

// The string a dispatch may carry, or "" for "there is nothing safe to send".
// Callers read "" as "no workspace" rather than guessing at what was meant.
function workspaceRef(value) {
  return isWorkspaceRef(value) ? String(value).trim() : ""
}

function asWorkspace(value) {
  if (value === undefined || value === null || value === "") return null
  if (typeof value === "number" && isFinite(value)) return Math.round(value)
  var s = String(value).trim()
  if (s === "") return null
  if (/^-?\d+$/.test(s)) return parseInt(s, 10)
  return isWorkspaceRef(s) ? s : null
}

function asStringList(value) {
  if (!Array.isArray(value)) return []
  var out = []
  for (var i = 0; i < value.length; i++) {
    var s = asString(value[i], "").trim()
    if (s !== "") out.push(s)
  }
  return out
}

// -------------------------------------------------------------------- ids

function slugify(name) {
  var s = asString(name, "").toLowerCase()
  s = s.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  if (s.length > 48) s = s.slice(0, 48).replace(/-+$/, "")
  return s
}

function isValidId(id) {
  return typeof id === "string" && /^[a-z0-9][a-z0-9-]*$/.test(id) && id.length <= 48
}

function uniqueId(base, takenIds) {
  var root = isValidId(base) ? base : slugify(base)
  if (root === "") root = "mode"
  var taken = {}
  for (var i = 0; i < (takenIds || []).length; i++) taken[takenIds[i]] = true
  if (!taken[root]) return root
  var n = 2
  while (taken[root + "-" + n]) n++
  return root + "-" + n
}

// ------------------------------------------------------------ mode shape

function defaultMode(id, name) {
  return {
    id: asString(id, "mode"),
    name: asString(name, "Mode"),
    icon: "",
    description: "",
    enabled: true,
    appearance: { wallpaper: null, theme: null },
    notifications: { dnd: null },
    audio: { output: null },
    workspaces: { target: null },
    applications: [],
    commands: { onActivate: [], onDeactivate: [] },
    triggers: []
  }
}

// An application is a desktop id or a raw command, never both.
function normalizeApplication(raw) {
  if (typeof raw === "string") {
    var only = raw.trim()
    return only === "" ? null : { desktopId: "", command: only, workspace: null, note: "", enabled: true }
  }
  if (!isPlainObject(raw)) return null
  var desktopId = asString(raw.desktopId, "").trim()
  if (desktopId.slice(-8) === ".desktop") desktopId = desktopId.slice(0, -8)
  var command = asString(raw.command, "").trim()
  if (desktopId === "" && command === "") return null
  if (desktopId !== "") command = ""
  return {
    desktopId: desktopId,
    command: command,
    workspace: asWorkspace(raw.workspace),
    // Display only, set by capture from the window title. Never affects launch.
    note: asString(raw.note, "").trim().slice(0, 120),
    enabled: asBool(raw.enabled, true)
  }
}

function applicationLabel(app) {
  if (!isPlainObject(app)) return ""
  return app.desktopId ? String(app.desktopId) : String(app.command || "")
}

function normalizeTrigger(raw) {
  if (!isPlainObject(raw)) return null
  var type = asString(raw.type, "").trim().toLowerCase()
  if (TRIGGER_TYPES.indexOf(type) === -1) return null
  var value = asString(raw.value, "").trim()
  if (value === "") return null
  var behavior = asString(raw.behavior, "").trim().toLowerCase()
  if (TRIGGER_BEHAVIORS.indexOf(behavior) === -1) behavior = ""
  return {
    type: type,
    value: value,
    enabled: asBool(raw.enabled, true),
    behavior: behavior
  }
}

function normalizeMode(raw, takenIds) {
  if (!isPlainObject(raw)) return null

  var name = asString(raw.name, "").trim()
  var id = asString(raw.id, "").trim().toLowerCase()
  if (!isValidId(id)) id = slugify(id || name)
  if (id === "") id = slugify(name)
  if (id === "") return null
  if (name === "") name = id

  var ctx = defaultMode(uniqueId(id, takenIds || []), name)
  ctx.icon = asString(raw.icon, "").trim()
  ctx.description = asString(raw.description, "").trim()
  ctx.enabled = asBool(raw.enabled, true)

  var appearance = isPlainObject(raw.appearance) ? raw.appearance : {}
  var wallpaper = asString(appearance.wallpaper, "").trim()
  var theme = asString(appearance.theme, "").trim()
  ctx.appearance.wallpaper = wallpaper === "" ? null : wallpaper
  ctx.appearance.theme = theme === "" ? null : theme

  var notifications = isPlainObject(raw.notifications) ? raw.notifications : {}
  ctx.notifications.dnd = asTristate(notifications.dnd)

  var audio = isPlainObject(raw.audio) ? raw.audio : {}
  var output = asString(audio.output, "").trim()
  ctx.audio.output = output === "" ? null : output

  var workspaces = isPlainObject(raw.workspaces) ? raw.workspaces : {}
  ctx.workspaces.target = asWorkspace(workspaces.target)

  var apps = Array.isArray(raw.applications) ? raw.applications : []
  for (var i = 0; i < apps.length; i++) {
    var app = normalizeApplication(apps[i])
    if (app) ctx.applications.push(app)
  }

  var commands = isPlainObject(raw.commands) ? raw.commands : {}
  ctx.commands.onActivate = asStringList(commands.onActivate)
  ctx.commands.onDeactivate = asStringList(commands.onDeactivate)

  var triggers = Array.isArray(raw.triggers) ? raw.triggers : []
  for (var t = 0; t < triggers.length; t++) {
    var trigger = normalizeTrigger(triggers[t])
    if (trigger) ctx.triggers.push(trigger)
  }

  return ctx
}

// ------------------------------------------------------------- config shape

function defaultBehavior() {
  return {
    confirmAutomaticSwitch: true,
    confirmWindowsOnSwitch: true,
    showNotifications: true,
    launchApps: true,
    triggersEnabled: false,
    restoreOnStart: false
  }
}

function defaultUi() {
  return { showIcon: true, showName: true }
}

function defaultConfig() {
  return {
    version: SCHEMA_VERSION,
    activeMode: null,
    behavior: defaultBehavior(),
    ui: defaultUi(),
    modes: []
  }
}

function normalizeConfig(raw) {
  var warnings = []
  var config = defaultConfig()

  if (!isPlainObject(raw)) {
    if (raw !== null && raw !== undefined) warnings.push("Config root was not an object; started from defaults.")
    return { config: config, warnings: warnings }
  }

  if (raw.version !== undefined && raw.version !== SCHEMA_VERSION) {
    warnings.push("Config version " + asString(raw.version, "?") + " is not version " + SCHEMA_VERSION + "; read on a best-effort basis.")
  }

  var behavior = isPlainObject(raw.behavior) ? raw.behavior : {}
  var defaults = defaultBehavior()
  for (var bk in defaults) config.behavior[bk] = asBool(behavior[bk], defaults[bk])

  var ui = isPlainObject(raw.ui) ? raw.ui : {}
  var uiDefaults = defaultUi()
  for (var uk in uiDefaults) config.ui[uk] = asBool(ui[uk], uiDefaults[uk])

  var list = Array.isArray(raw.modes) ? raw.modes : []
  if (raw.modes !== undefined && !Array.isArray(raw.modes))
    warnings.push("`modes` was not a list; ignored.")

  var ids = []
  for (var i = 0; i < list.length; i++) {
    var ctx = normalizeMode(list[i], ids)
    if (!ctx) {
      warnings.push("Dropped a mode entry that could not be read.")
      continue
    }
    ids.push(ctx.id)
    config.modes.push(ctx)
  }

  var active = asString(raw.activeMode, "").trim()
  config.activeMode = (active !== "" && ids.indexOf(active) !== -1) ? active : null
  if (active !== "" && config.activeMode === null)
    warnings.push("Active mode \"" + active + "\" no longer exists; cleared.")

  return { config: config, warnings: warnings }
}

function parseConfig(text) {
  var raw = asString(text, "").trim()
  if (raw === "") return { config: defaultConfig(), warnings: [], recovered: false, firstRun: true }
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return {
      config: defaultConfig(),
      warnings: ["omara.json is not valid JSON (" + (e && e.message ? e.message : "parse error") + "). Using defaults; the file was left untouched."],
      recovered: true,
      firstRun: false
    }
  }
  var result = normalizeConfig(parsed)
  return { config: result.config, warnings: result.warnings, recovered: false, firstRun: false }
}

function serializeConfig(config) {
  var result = normalizeConfig(config)
  return JSON.stringify(result.config, null, 2) + "\n"
}

// ------------------------------------------------------------------- CRUD

function modeIds(config) {
  var out = []
  var list = (config && Array.isArray(config.modes)) ? config.modes : []
  for (var i = 0; i < list.length; i++) out.push(list[i].id)
  return out
}

function findMode(config, id) {
  var key = asString(id, "")
  var list = (config && Array.isArray(config.modes)) ? config.modes : []
  for (var i = 0; i < list.length; i++) if (list[i].id === key) return list[i]
  return null
}

function indexOfMode(config, id) {
  var key = asString(id, "")
  var list = (config && Array.isArray(config.modes)) ? config.modes : []
  for (var i = 0; i < list.length; i++) if (list[i].id === key) return i
  return -1
}

function createMode(config, fields) {
  var next = clone(config)
  var f = isPlainObject(fields) ? fields : {}
  var name = asString(f.name, "").trim() || "New mode"
  var id = uniqueId(asString(f.id, "").trim() || slugify(name), modeIds(next))
  var ctx = normalizeMode({
    id: id,
    name: name,
    icon: asString(f.icon, ""),
    description: asString(f.description, ""),
    appearance: f.appearance,
    notifications: f.notifications,
    audio: f.audio,
    workspaces: f.workspaces,
    applications: f.applications,
    commands: f.commands,
    triggers: f.triggers
  }, modeIds(next))
  next.modes.push(ctx)
  return { config: next, mode: ctx }
}

function updateMode(config, id, fields) {
  var next = clone(config)
  var index = indexOfMode(next, id)
  if (index === -1) return { config: next, mode: null, error: "No mode with id \"" + asString(id, "") + "\"" }
  var merged = clone(next.modes[index])
  var f = isPlainObject(fields) ? fields : {}
  for (var key in f) {
    if (key === "id") continue
    merged[key] = f[key]
  }
  var others = modeIds(next)
  others.splice(index, 1)
  var normalized = normalizeMode(merged, others)
  if (!normalized) return { config: next, mode: null, error: "Rejected an unreadable update" }
  normalized.id = next.modes[index].id
  next.modes[index] = normalized
  return { config: next, mode: normalized, error: "" }
}

// Moves an item within a list, clamped. Returns a new array; an out-of-range
// index or a no-op move comes back unchanged so callers can stay dumb.
function moveInList(list, index, delta) {
  var out = Array.isArray(list) ? list.slice() : []
  var from = Number(index)
  if (!isFinite(from) || from < 0 || from >= out.length) return out
  var to = from + Number(delta)
  if (to < 0 || to >= out.length) return out
  var item = out.splice(from, 1)[0]
  out.splice(to, 0, item)
  return out
}

function moveMode(config, id, delta) {
  var next = clone(config)
  var index = indexOfMode(next, id)
  if (index === -1) return { config: next, moved: false }
  var before = modeIds(next).join(",")
  next.modes = moveInList(next.modes, index, delta)
  return { config: next, moved: modeIds(next).join(",") !== before }
}

function deleteMode(config, id) {
  var next = clone(config)
  var index = indexOfMode(next, id)
  if (index === -1) return { config: next, removed: false }
  next.modes.splice(index, 1)
  if (next.activeMode === id) next.activeMode = null
  return { config: next, removed: true }
}

function setActiveMode(config, id) {
  var next = clone(config)
  next.activeMode = (id === null || id === undefined || id === "") ? null : asString(id, "")
  if (next.activeMode !== null && indexOfMode(next, next.activeMode) === -1) next.activeMode = null
  return next
}

// ------------------------------------------------------- argv tokenization

// Shell-like tokenizing, not a shell: no globbing, substitution, or operators.
function parseArgv(command) {
  var s = asString(command, "")
  var argv = []
  var current = ""
  var has = false
  var quote = ""
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i)
    if (quote) {
      if (c === quote) { quote = "" }
      else if (c === "\\" && quote === "\"" && i + 1 < s.length) { i++; current += s.charAt(i); has = true }
      else { current += c; has = true }
      continue
    }
    if (c === "'" || c === "\"") { quote = c; has = true; continue }
    if (c === "\\" && i + 1 < s.length) { i++; current += s.charAt(i); has = true; continue }
    if (c === " " || c === "\t" || c === "\n") {
      if (has) { argv.push(current); current = ""; has = false }
      continue
    }
    current += c
    has = true
  }
  if (has) argv.push(current)
  return { argv: argv, unterminated: quote !== "" }
}

// Hyprland places a window with an exec rule; `silent` leaves focus alone. The
// workspace is interpolated raw, so it has to clear isWorkspaceRef first. One
// that does not launches the application unplaced instead of shaping the rule.
function hyprlandExecRule(workspace, command) {
  var target = workspaceRef(workspace)
  var payload = String(command || "")
  if (target === "") return payload
  return "[workspace " + target + " silent] " + payload
}

// A Lua string literal for the keyword dispatch path. A bare newline is a
// syntax error there, not just an odd name, so it is escaped like the rest.
function luaQuote(value) {
  return '"' + String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r") + '"'
}

// ------------------------------------------------------------ activation

function activationPlan(mode, options) {
  var opts = isPlainObject(options) ? options : {}
  var steps = []
  if (!isPlainObject(mode)) return steps

  var settingsOnly = opts.settingsOnly === true

  if (mode.notifications && mode.notifications.dnd !== null && mode.notifications.dnd !== undefined)
    steps.push({ kind: "dnd", label: mode.notifications.dnd ? "Enable Do Not Disturb" : "Disable Do Not Disturb", value: mode.notifications.dnd })

  if (mode.audio && mode.audio.output)
    steps.push({ kind: "audio", label: "Switch audio output", value: mode.audio.output })

  if (mode.appearance && mode.appearance.wallpaper)
    steps.push({ kind: "wallpaper", label: "Set wallpaper", value: mode.appearance.wallpaper })

  if (mode.appearance && mode.appearance.theme)
    steps.push({ kind: "theme", label: "Set theme", value: mode.appearance.theme })

  var landing = mode.workspaces && mode.workspaces.target !== null && mode.workspaces.target !== undefined
    ? mode.workspaces.target : null
  var focusStep = landing === null ? null : { kind: "workspace", label: "Focus workspace", value: landing }

  // Focus goes last. An application that lands on the wrong workspace would
  // otherwise drag you off the one the mode is supposed to leave you on.
  if (settingsOnly) {
    if (focusStep) steps.push(focusStep)
    return steps
  }

  if (opts.launchApps !== false) {
    var apps = Array.isArray(mode.applications) ? mode.applications : []
    for (var i = 0; i < apps.length; i++) {
      if (apps[i].enabled === false) continue
      var workspace = apps[i].workspace === undefined ? null : apps[i].workspace
      steps.push({
        kind: "applications",
        label: "Launch " + applicationLabel(apps[i])
          + (workspace === null ? "" : " on workspace " + workspace),
        value: apps[i].command || "",
        desktopId: apps[i].desktopId || "",
        workspace: workspace
      })
    }
  }

  var commands = (mode.commands && Array.isArray(mode.commands.onActivate)) ? mode.commands.onActivate : []
  for (var c = 0; c < commands.length; c++)
    steps.push({ kind: "commands", label: "Run " + commands[c], value: commands[c] })

  if (focusStep) steps.push(focusStep)

  return steps
}

function deactivationPlan(mode) {
  var steps = []
  if (!isPlainObject(mode)) return steps
  var commands = (mode.commands && Array.isArray(mode.commands.onDeactivate)) ? mode.commands.onDeactivate : []
  for (var i = 0; i < commands.length; i++)
    steps.push({ kind: "commands", label: "Run " + commands[i], value: commands[i] })
  return steps
}

// Restores only values this plugin set, and only if they are still what it set.
function restorePlan(snapshot, current) {
  var steps = []
  if (!isPlainObject(snapshot)) return steps
  var live = isPlainObject(current) ? current : {}

  if (snapshot.dnd !== undefined && snapshot.dnd !== null) {
    var appliedDnd = snapshot.appliedDnd
    if (appliedDnd === undefined || live.dnd === undefined || live.dnd === appliedDnd)
      steps.push({ kind: "dnd", label: "Restore Do Not Disturb", value: snapshot.dnd })
  }
  if (snapshot.audioOutput) {
    if (!snapshot.appliedAudioOutput || !live.audioOutput || live.audioOutput === snapshot.appliedAudioOutput)
      steps.push({ kind: "audio", label: "Restore audio output", value: snapshot.audioOutput })
  }
  if (snapshot.wallpaper) {
    if (!snapshot.appliedWallpaper || !live.wallpaper || live.wallpaper === snapshot.appliedWallpaper)
      steps.push({ kind: "wallpaper", label: "Restore wallpaper", value: snapshot.wallpaper })
  }
  if (snapshot.theme) {
    if (!snapshot.appliedTheme || !live.theme || live.theme === snapshot.appliedTheme)
      steps.push({ kind: "theme", label: "Restore theme", value: snapshot.theme })
  }
  return steps
}

function summarize(modeName, results) {
  var warnings = 0
  var list = Array.isArray(results) ? results : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].ok === false) warnings++
  if (warnings === 0) return { headline: modeName, body: "", warnings: 0 }
  return {
    headline: modeName,
    body: warnings === 1 ? "Activated with 1 warning" : "Activated with " + warnings + " warnings",
    warnings: warnings
  }
}

// ------------------------------------------------------------- import/export

function modeHasCommands(mode) {
  if (!isPlainObject(mode)) return false
  var c = mode.commands
  if (isPlainObject(c)) {
    if (Array.isArray(c.onActivate) && c.onActivate.length > 0) return true
    if (Array.isArray(c.onDeactivate) && c.onDeactivate.length > 0) return true
  }
  return Array.isArray(mode.applications) && mode.applications.length > 0
}

// Every program an imported mode would run, written the way it would run it.
// The preview lists these verbatim: "3 modes, some of which run programs" is a
// count, and a count is not consent.
function importRuns(mode) {
  var out = []
  if (!isPlainObject(mode)) return out
  var apps = Array.isArray(mode.applications) ? mode.applications : []
  for (var i = 0; i < apps.length; i++) {
    var app = apps[i]
    if (!isPlainObject(app)) continue
    if (app.desktopId) out.push("app  " + app.desktopId + ".desktop")
    else if (app.command) out.push("app  " + app.command)
  }
  var c = isPlainObject(mode.commands) ? mode.commands : {}
  var hooks = (Array.isArray(c.onActivate) ? c.onActivate : [])
    .concat(Array.isArray(c.onDeactivate) ? c.onDeactivate : [])
  for (var j = 0; j < hooks.length; j++) out.push("sh   " + hooks[j])
  return out
}

// An `auto` trigger runs a mode, and so its commands, the first time a matching
// window opens, with no further click from you. Importing a file cannot hand
// out that standing permission, so imported triggers arrive asking. Promoting
// one back to automatic is an edit you make yourself, on a mode you have read.
//
// "" is pinned to "ask" too, not just "auto": the default defers to your global
// *Ask before switching* setting, so on a machine where that is off an imported
// blank would resolve to automatic. The file does not get to inherit that.
function disarmImportedTriggers(mode) {
  var count = 0
  var triggers = (isPlainObject(mode) && Array.isArray(mode.triggers)) ? mode.triggers : []
  for (var i = 0; i < triggers.length; i++) {
    if (!isPlainObject(triggers[i]) || triggers[i].behavior === "ask") continue
    triggers[i].behavior = "ask"
    count++
  }
  return count
}

// What the import pane renders: one entry per mode, each carrying the exact
// command lines that mode would run.
function importPreview(modes) {
  var list = Array.isArray(modes) ? modes : []
  var out = []
  for (var i = 0; i < list.length; i++)
    out.push({
      id: asString(list[i] && list[i].id, ""),
      name: asString(list[i] && list[i].name, ""),
      runs: importRuns(list[i])
    })
  return out
}

function exportPayload(config, ids) {
  var wanted = Array.isArray(ids) ? ids : null
  var list = (config && Array.isArray(config.modes)) ? config.modes : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (wanted && wanted.indexOf(list[i].id) === -1) continue
    var ctx = clone(list[i])
    delete ctx.enabled
    out.push(ctx)
  }
  return { version: SCHEMA_VERSION, kind: "omara-export", modes: out }
}

function parseImport(text) {
  var raw = asString(text, "").trim()
  if (raw === "") return { modes: [], error: "The file is empty." }
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { modes: [], error: "Not valid JSON (" + (e && e.message ? e.message : "parse error") + ")." }
  }
  var list = null
  if (Array.isArray(parsed)) list = parsed
  else if (isPlainObject(parsed) && Array.isArray(parsed.modes)) list = parsed.modes
  else if (isPlainObject(parsed)) list = [parsed]
  if (!list) return { modes: [], error: "No modes found in the file." }

  var out = []
  var ids = []
  var disarmed = 0
  for (var i = 0; i < list.length; i++) {
    var ctx = normalizeMode(list[i], ids)
    if (!ctx) continue
    disarmed += disarmImportedTriggers(ctx)
    ids.push(ctx.id)
    out.push(ctx)
  }
  if (out.length === 0) return { modes: [], error: "No modes found in the file." }
  return { modes: out, error: "", disarmed: disarmed }
}

function importModes(config, incoming, mode) {
  var next = clone(config)
  var how = (mode === "replace" || mode === "skip") ? mode : "copy"
  var added = []
  var replaced = []
  var skipped = []
  var list = Array.isArray(incoming) ? incoming : []

  for (var i = 0; i < list.length; i++) {
    var ctx = clone(list[i])
    var index = indexOfMode(next, ctx.id)
    if (index === -1) {
      var fresh = normalizeMode(ctx, modeIds(next))
      if (!fresh) continue
      next.modes.push(fresh)
      added.push(fresh.id)
      continue
    }
    if (how === "skip") { skipped.push(ctx.id); continue }
    if (how === "replace") {
      var others = modeIds(next)
      others.splice(index, 1)
      var normalized = normalizeMode(ctx, others)
      if (!normalized) continue
      normalized.id = next.modes[index].id
      next.modes[index] = normalized
      replaced.push(normalized.id)
      continue
    }
    delete ctx.id
    var copy = normalizeMode(ctx, modeIds(next))
    if (!copy) continue
    copy.name = ctx.name ? ctx.name + " (copy)" : copy.name
    next.modes.push(copy)
    added.push(copy.id)
  }

  return { config: next, added: added, replaced: replaced, skipped: skipped }
}

// ------------------------------------------------------------ probe output

// Ceilings on what a subprocess may hand back. The producers are bounded at
// the source too, but a parser that trusts its input to respect its own limits
// is not applying a limit.
var PROBE_MAX_BYTES = 65536
var PROBE_MAX_LINES = 512
var PROBE_MAX_ITEMS = 512
var PROBE_MAX_FIELD = 4096

function probeField(value) {
  var s = typeof value === "string" ? value : ""
  return s.length > PROBE_MAX_FIELD ? s.slice(0, PROBE_MAX_FIELD) : s
}

// A closed record: three known keys, and nothing the output can add to them.
// `missing` is null-prototype because the lookup is `missing[name] === true` —
// on a plain object a command called `toString` or `valueOf` would come back
// truthy off the prototype chain and be reported as not installed.
function parseProbeOutput(text) {
  var out = { wallpaper: "", theme: "", missing: Object.create(null) }
  var raw = typeof text === "string" ? text : String(text === undefined || text === null ? "" : text)
  if (raw.length > PROBE_MAX_BYTES) raw = raw.slice(0, PROBE_MAX_BYTES)

  var lines = raw.split("\n")
  var limit = lines.length < PROBE_MAX_LINES ? lines.length : PROBE_MAX_LINES
  for (var i = 0; i < limit; i++) {
    var parts = lines[i].split("\t")
    if (parts[0] === "WALLPAPER") out.wallpaper = probeField(parts[1])
    else if (parts[0] === "THEME") out.theme = probeField(parts[1])
    else if (parts[0] === "APP" && parts[1] === "missing") {
      var name = probeField(parts[2])
      if (name !== "") out.missing[name] = true
    }
  }
  return out
}

function emptyProbeResult() {
  return { wallpaper: "", theme: "", missing: Object.create(null) }
}

// ---------------------------------------------------------------- triggers

// --------------------------------------------------------- window placement

// Hyprland places a window using the pid its exec rule spawned. Apps that fork
// and re-exec, Chromium among them, hand the window to a different process and
// land on the active workspace instead. So remember where each launch was meant
// to go and move the window when it actually shows up.
var PLACEMENT_TTL_MS = 25000

function placementKeys(desktopId, command, startupClass) {
  var keys = []
  function add(value) {
    var s = asString(value, "").trim().toLowerCase()
    if (s === "") return
    s = s.split("/").pop()
    if (s.length >= 3 && keys.indexOf(s) === -1) keys.push(s)
    // org.chromium.Chromium and chromium are the same app to a window class.
    var tail = s.split(".").pop()
    if (tail !== s && tail.length >= 3 && keys.indexOf(tail) === -1) keys.push(tail)
  }
  add(startupClass)
  add(desktopId)
  add(command)
  return keys
}

function prunePlacements(pending, now) {
  var out = []
  var list = Array.isArray(pending) ? pending : []
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!isPlainObject(p)) continue
    if (now - (Number(p.at) || 0) > PLACEMENT_TTL_MS) continue
    out.push(p)
  }
  return out
}

function matchPlacement(pending, windowClass, now) {
  var cls = asString(windowClass, "").trim().toLowerCase()
  if (cls.length < 3) return -1
  var list = Array.isArray(pending) ? pending : []
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!isPlainObject(p)) continue
    if (now - (Number(p.at) || 0) > PLACEMENT_TTL_MS) continue
    var keys = Array.isArray(p.keys) ? p.keys : []
    for (var k = 0; k < keys.length; k++) {
      var key = asString(keys[k], "").toLowerCase()
      if (key.length < 3) continue
      if (cls === key || cls.indexOf(key) !== -1 || key.indexOf(cls) !== -1) return i
    }
  }
  return -1
}

function parseOpenWindowEvent(data) {
  var s = asString(data, "")
  var parts = s.split(",")
  if (parts.length < 3) return null
  return {
    address: parts[0],
    workspace: parts[1],
    windowClass: parts[2],
    title: parts.slice(3).join(",")
  }
}

function triggerMatches(trigger, event) {
  if (!isPlainObject(trigger) || !isPlainObject(event)) return false
  if (trigger.enabled === false) return false
  if (trigger.type !== "application") return false
  var needle = asString(trigger.value, "").toLowerCase()
  if (needle === "") return false
  var hay = asString(event.windowClass, "").toLowerCase()
  if (hay === "") return false
  return hay === needle || hay.indexOf(needle) !== -1
}

// Loop prevention lives here: already-active, activation cooldown, disabled.
function evaluateTrigger(config, event, state) {
  var result = { action: "ignore", modeId: "", reason: "" }
  if (!isPlainObject(config) || config.behavior.triggersEnabled !== true) {
    result.reason = "triggers disabled"
    return result
  }
  var s = isPlainObject(state) ? state : {}
  var now = typeof s.now === "number" ? s.now : 0
  var last = typeof s.lastActivationAt === "number" ? s.lastActivationAt : -Infinity
  var cooldown = typeof s.cooldownMs === "number" ? s.cooldownMs : TRIGGER_COOLDOWN_MS

  var list = Array.isArray(config.modes) ? config.modes : []
  for (var i = 0; i < list.length; i++) {
    var ctx = list[i]
    if (ctx.enabled === false) continue
    var triggers = Array.isArray(ctx.triggers) ? ctx.triggers : []
    for (var t = 0; t < triggers.length; t++) {
      if (!triggerMatches(triggers[t], event)) continue
      if (config.activeMode === ctx.id) {
        result.reason = "already active"
        return result
      }
      if (now - last < cooldown) {
        result.reason = "within activation cooldown"
        return result
      }
      var behavior = triggers[t].behavior
      if (behavior !== "ask" && behavior !== "auto")
        behavior = config.behavior.confirmAutomaticSwitch ? "ask" : "auto"
      result.action = behavior === "auto" ? "switch" : "ask"
      result.modeId = ctx.id
      result.reason = "trigger matched " + triggers[t].value
      return result
    }
  }
  result.reason = "no match"
  return result
}

// --------------------------------------------------------------- capture

// Shape a snapshot of the running desktop into mode fields. Takes plain
// data so it stays testable; the caller gathers it from Hyprland/PipeWire.
//
// state: { name, description, workspace, dnd, audioOutput, wallpaper, theme,
//          windows: [{ desktopId, command, workspace }] }
function captureMode(state) {
  var s = isPlainObject(state) ? state : {}
  var windows = Array.isArray(s.windows) ? s.windows : []

  var apps = []
  var seen = {}
  for (var i = 0; i < windows.length; i++) {
    var w = isPlainObject(windows[i]) ? windows[i] : {}
    var app = normalizeApplication({
      desktopId: w.desktopId,
      command: w.command,
      workspace: w.workspace,
      note: w.title,
      enabled: true
    })
    if (!app) continue
    // Three terminals on one workspace are one entry, not three.
    var key = (app.desktopId || app.command) + "@" + String(app.workspace)
    if (seen[key]) continue
    seen[key] = true
    apps.push(app)
  }

  apps.sort(function(a, b) {
    var aw = a.workspace === null ? Infinity : Number(a.workspace)
    var bw = b.workspace === null ? Infinity : Number(b.workspace)
    if (isFinite(aw) && isFinite(bw) && aw !== bw) return aw - bw
    return applicationLabel(a).toLowerCase() < applicationLabel(b).toLowerCase() ? -1 : 1
  })

  return {
    name: asString(s.name, "").trim() || "Current desktop",
    description: asString(s.description, "").trim(),
    workspaces: { target: asWorkspace(s.workspace) },
    notifications: { dnd: asTristate(s.dnd) },
    audio: { output: asString(s.audioOutput, "").trim() || null },
    appearance: {
      wallpaper: asString(s.wallpaper, "").trim() || null,
      theme: asString(s.theme, "").trim() || null
    },
    applications: apps,
    commands: { onActivate: [], onDeactivate: [] },
    triggers: []
  }
}

// ------------------------------------------------------------------ glyphs

// One place for every icon in the UI, so sizes and shapes stay consistent.
// Material Design Icons from the Nerd Font patch, which every font Omarchy
// offers as `monospace` carries. Render these at Style.font.icon, never
// inline in a label. Each one is checked to draw a real shape: a codepoint
// can be in the font's cmap and still paint a filled box.
var Glyph = {
  add: "\u{f0415}",
  close: "\u{f0156}",
  check: "\u{f012c}",
  refresh: "\u{f0453}",
  chevronUp: "\u{f0143}",
  chevronDown: "\u{f0140}",
  chevronRight: "\u{f0142}",
  settings: "\u{f0493}",
  capture: "\u{f0100}",
  blank: "\u{f0224}",
  importFile: "\u{f02fa}",
  exportFile: "\u{f0207}",
  remove: "\u{f01b4}",
  duplicate: "\u{f018f}",
  power: "\u{f0425}"
}

// ----------------------------------------------------------------- themes

// Omarchy stores a theme as a directory slug and writes that slug to
// theme.name, so the slug is what a mode stores. The pretty form is only
// ever for display.
function prettyThemeName(slug) {
  var parts = String(slug || "").split("-")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    out.push(parts[i].charAt(0).toUpperCase() + parts[i].slice(1))
  }
  return out.join(" ")
}

function themeList(slugs) {
  // Null-prototype: a theme directory called `constructor` or `toString` would
  // otherwise read as already-seen off the prototype chain and vanish.
  var seen = Object.create(null)
  var out = []
  var list = Array.isArray(slugs) ? slugs : []
  var limit = list.length < PROBE_MAX_ITEMS ? list.length : PROBE_MAX_ITEMS
  for (var i = 0; i < limit; i++) {
    var slug = String(list[i] || "").trim()
    if (slug === "" || slug.length > PROBE_MAX_FIELD || seen[slug]) continue
    seen[slug] = true
    out.push({ slug: slug, name: prettyThemeName(slug) })
  }
  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

function filterThemes(themes, query) {
  var needle = String(query || "").trim().toLowerCase()
  var list = Array.isArray(themes) ? themes : []
  if (needle === "") return list
  var out = []
  for (var i = 0; i < list.length; i++)
    if ((list[i].slug + " " + list[i].name).toLowerCase().indexOf(needle) !== -1) out.push(list[i])
  return out
}

// ------------------------------------------------------- switching windows

// What to do with the windows already on screen when a mode is activated.
function windowSwitchMode(behavior, requested, hasWindows) {
  var mode = String(requested || "")
  if (mode === "close" || mode === "keep") return mode
  if (!hasWindows) return "keep"
  var b = isPlainObject(behavior) ? behavior : {}
  return b.confirmWindowsOnSwitch === false ? "keep" : "ask"
}

function switchPromptMessage(modeName, windowCount) {
  var n = Math.max(0, Number(windowCount) || 0)
  return "Switching to \"" + asString(modeName, "this mode") + "\".\n\n" +
    n + (n === 1 ? " window is" : " windows are") + " open right now."
}

// --------------------------------------------------------------- templates

function templates() {
  return [
    {
      key: "blank",
      name: "Blank",
      description: "An empty mode to fill in yourself",
      mode: {}
    }
  ]
}

function templateMode(key, existingIds) {
  var list = templates()
  for (var i = 0; i < list.length; i++) {
    if (list[i].key !== key) continue
    var seed = clone(list[i].mode)
    seed.name = list[i].name
    seed.id = uniqueId(list[i].key, existingIds || [])
    return normalizeMode(seed, existingIds || [])
  }
  return null
}

// ------------------------------------------------------------------ exports

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    SCHEMA_VERSION: SCHEMA_VERSION,
    ACTION_KINDS: ACTION_KINDS,
    TRIGGER_TYPES: TRIGGER_TYPES,
    TRIGGER_COOLDOWN_MS: TRIGGER_COOLDOWN_MS,
    isPlainObject: isPlainObject,
    clone: clone,
    asTristate: asTristate,
    asWorkspace: asWorkspace,
    slugify: slugify,
    isValidId: isValidId,
    uniqueId: uniqueId,
    defaultMode: defaultMode,
    normalizeApplication: normalizeApplication,
    applicationLabel: applicationLabel,
    hyprlandExecRule: hyprlandExecRule,
    luaQuote: luaQuote,
    isWorkspaceRef: isWorkspaceRef,
    workspaceRef: workspaceRef,
    normalizeMode: normalizeMode,
    defaultConfig: defaultConfig,
    normalizeConfig: normalizeConfig,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    modeIds: modeIds,
    findMode: findMode,
    indexOfMode: indexOfMode,
    createMode: createMode,
    updateMode: updateMode,
    deleteMode: deleteMode,
    moveInList: moveInList,
    moveMode: moveMode,
    setActiveMode: setActiveMode,
    parseArgv: parseArgv,
    activationPlan: activationPlan,
    deactivationPlan: deactivationPlan,
    restorePlan: restorePlan,
    summarize: summarize,
    modeHasCommands: modeHasCommands,
    exportPayload: exportPayload,
    parseImport: parseImport,
    importModes: importModes,
    importRuns: importRuns,
    importPreview: importPreview,
    disarmImportedTriggers: disarmImportedTriggers,
    PLACEMENT_TTL_MS: PLACEMENT_TTL_MS,
    placementKeys: placementKeys,
    parseProbeOutput: parseProbeOutput,
    emptyProbeResult: emptyProbeResult,
    prunePlacements: prunePlacements,
    matchPlacement: matchPlacement,
    parseOpenWindowEvent: parseOpenWindowEvent,
    triggerMatches: triggerMatches,
    evaluateTrigger: evaluateTrigger,
    captureMode: captureMode,
    Glyph: Glyph,
    prettyThemeName: prettyThemeName,
    themeList: themeList,
    filterThemes: filterThemes,
    windowSwitchMode: windowSwitchMode,
    switchPromptMessage: switchPromptMessage,
    templates: templates,
    templateMode: templateMode
  }
}

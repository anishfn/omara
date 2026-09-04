
// Pure logic: schema, activation plans, triggers, import/export.
// No Qt or Quickshell here, which is what lets tests/ run it under node.

// ---------------------------------------------------------------- constants

var SCHEMA_VERSION = 1

var ACTION_KINDS = ["dnd", "audio", "wallpaper", "theme", "workspace", "applications", "commands"]

var TRIGGER_TYPES = ["application"]
var TRIGGER_BEHAVIORS = ["ask", "auto"]

var TRIGGER_COOLDOWN_MS = 8000

// Ceilings on anything that arrives as a document rather than as a click.
// A config or an import is parsed, cloned and rendered, so an unbounded one
// exhausts the shell long before a person could read the preview. These are
// generous next to any real mode file and cheap to enforce.
var MAX_IMPORT_BYTES = 4194304
var MAX_MODES = 200
var MAX_APPLICATIONS = 100
var MAX_HOOKS = 50
var MAX_TRIGGERS = 50
var MAX_STRING = 2048
var MAX_COMMAND = 4096

// ---------------------------------------------------------------- utilities

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function clone(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value))
}

// Every string that arrives from a file goes through here, so the clamp lives
// with the conversion rather than at each call site.
function clampString(value, limit) {
  var s = typeof value === "string" ? value : ""
  var cap = limit || MAX_STRING
  return s.length > cap ? s.slice(0, cap) : s
}

function asString(value, fallback) {
  if (value === undefined || value === null) return fallback === undefined ? "" : fallback
  if (typeof value === "string") return clampString(value)
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

function asStringList(value, maxItems, maxLength) {
  if (!Array.isArray(value)) return []
  var out = []
  var cap = maxItems || MAX_HOOKS
  var limit = value.length < cap ? value.length : cap
  for (var i = 0; i < limit; i++) {
    var s = clampString(asString(value[i], ""), maxLength || MAX_STRING).trim()
    if (s !== "") out.push(s)
  }
  return out
}

// ------------------------------------------------------------------ paths
//
// A folder is stored the way you would type it — `~/Projects`, not
// `/home/you/Projects` — so a mode exported off one machine still opens the
// right thing on another. `~` is expanded once, at launch.

function prettyDirectory(value) {
  var s = asString(value, "").trim()
  if (s === "") return ""
  while (s.length > 1 && s.charAt(s.length - 1) === "/") s = s.slice(0, -1)
  return s
}

function collapseHome(path, home) {
  var p = prettyDirectory(path)
  var h = prettyDirectory(home)
  if (p === "" || h === "" || h === "/") return p
  if (p === h) return "~"
  if (p.indexOf(h + "/") === 0) return "~" + p.slice(h.length)
  return p
}

function expandHome(path, home) {
  var p = prettyDirectory(path)
  var h = prettyDirectory(home)
  if (p === "" || h === "") return p
  if (p === "~") return h
  if (p.indexOf("~/") === 0) return h + p.slice(1)
  return p
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
    workspaces: { target: null, layouts: [] },
    applications: [],
    commands: { onActivate: [], onDeactivate: [] },
    triggers: []
  }
}

// How long an argument string or a folder is allowed to be. Long enough for a
// real URL, short enough that a pasted blob cannot become the config.
var MAX_ARGS = 512
var MAX_DIRECTORY = 512

// An application is a desktop id or a raw command, never both. Either one can
// carry `args` (appended to the launch, parsed the way a shell would) and
// `directory` (the folder it starts in) — the two things a window has that its
// name does not say.
function normalizeApplication(raw) {
  if (typeof raw === "string") {
    var only = raw.trim()
    return only === "" ? null : {
      uid: "", desktopId: "", command: only, args: "", directory: "",
      workspace: null, note: "", enabled: true
    }
  }
  if (!isPlainObject(raw)) return null
  var desktopId = asString(raw.desktopId, "").trim()
  if (desktopId.slice(-8) === ".desktop") desktopId = desktopId.slice(0, -8)
  var command = asString(raw.command, "").trim()
  if (desktopId === "" && command === "") return null
  if (desktopId !== "") command = ""
  var uid = asString(raw.uid, "").trim()
  return {
    // Stable across a rename, a reorder, and a round trip through the config,
    // which is what lets a pane point at an application instead of an index.
    uid: UID_PATTERN.test(uid) ? uid : "",
    desktopId: desktopId,
    command: command,
    // One line, always: a newline in either would end up in a shell.
    args: asString(raw.args, "").replace(/[\r\n]+/g, " ").trim().slice(0, MAX_ARGS),
    // Through prettyDirectory so `~/Projects/` and `~/Projects` are one
    // folder, and so capture cannot split one app into two over a slash.
    directory: prettyDirectory(
      asString(raw.directory, "").replace(/[\r\n]+/g, " ").trim().slice(0, MAX_DIRECTORY)),
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

// ------------------------------------------------- terminals and commands
//
// A terminal is told what to run with `-e`, and everything after it is that
// command. Knowing that is not the user's job, so the editor offers "run
// this" and these two turn it into, and back out of, the argument string that
// is actually stored. Nothing new goes in the config: `-e btop` is still
// `-e btop`, whether you typed the flag or we did.

// Matched as a whole word, so `--exec-ish` and a path ending in `-e` are not
// mistaken for the flag.
var TERMINAL_EXEC_RE = /(^|\s)(-e|-x|--command|--execute)(?=\s|$)/

// A .desktop file declaring itself a terminal is the freedesktop-standard
// signal, and a far better one than guessing from the application's name.
//
// Length-indexed rather than Array.isArray: QML hands a `list<QString>` over
// as something array-like that is not a JS Array, so the tidier guard said no
// to every real desktop entry while every test passed on plain arrays.
function isTerminalCategories(categories) {
  if (!categories) return false
  var n = Number(categories.length)
  if (!isFinite(n) || n <= 0) return false
  for (var i = 0; i < n; i++)
    if (String(categories[i]).trim().toLowerCase() === "terminalemulator") return true
  return false
}

// What a terminal is handed to run a whole shell line, rather than one
// program: `-e bash -lc "<line>"`. A login shell because the line is yours and
// expects your PATH, the same way the activate/deactivate hooks do.
var TERMINAL_SHELL = "bash"
var TERMINAL_SHELL_FLAG = "-lc"
var SHELL_NAMES = ["bash", "sh", "zsh", "dash", "fish"]

// A command that fails takes its terminal down with it before you can read
// why, and the activity log still says the launch succeeded — because it did.
// A typo and a real fault look identical from the outside, so a non-zero exit
// keeps the window and drops you into a shell in it. Success is untouched:
// the command ends, the window closes.
//
// `__c=$?` has to come first. The next command in the block would otherwise
// have already reset `$?` to its own status by the time it is read.
var TERMINAL_KEEP_OPEN =
  ' || { __c=$?; echo; echo "[command exited $__c]"; exec bash; }'

// Appended on the way in and taken off on the way out, so what you typed is
// what you see. A line written by hand, without it, reads back unchanged.
function withKeepOpen(command) {
  return command + TERMINAL_KEEP_OPEN
}

function withoutKeepOpen(command) {
  var line = String(command === undefined || command === null ? "" : command)
  var tail = TERMINAL_KEEP_OPEN
  if (line.length > tail.length && line.slice(-tail.length) === tail)
    return line.slice(0, line.length - tail.length)
  return line
}

// Single quotes, with the standard '\'' break-out, which parseArgv reads back
// exactly. Nothing inside is ever seen as syntax.
function shellQuoteToken(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// The shell line back out of the arguments. A line we wrote comes back
// exactly, quotes and all; anything else — a hand-written mode, a capture —
// is shown as the raw tail rather than re-joined from tokens, because
// re-quoting is how `-c "cd x && y"` stops running.
function terminalCommandOf(args) {
  var raw = asString(args, "").trim()
  var parsed = parseArgv(raw)
  if (!parsed.unterminated) {
    var argv = parsed.argv
    for (var i = 0; i < argv.length; i++) {
      if (TERMINAL_EXEC_FLAGS.indexOf(argv[i]) === -1) continue
      var rest = argv.slice(i + 1)
      if (rest.length >= 3
          && SHELL_NAMES.indexOf(String(rest[0]).split("/").pop()) !== -1
          && /^-[a-z]*c$/.test(String(rest[1])))
        return withoutKeepOpen(rest[2])
      break
    }
  }
  var m = TERMINAL_EXEC_RE.exec(raw)
  return m ? raw.slice(m.index + m[0].length).trim() : ""
}

// One shell line in, the arguments a terminal understands out. Flags that came
// before the command are kept, so a terminal captured as `--title notes -e
// btop` does not lose its title when you change what it runs.
function setTerminalCommand(args, command) {
  var raw = asString(args, "").trim()
  var cmd = asString(command, "").replace(/[\r\n]+/g, " ").trim()
  var m = TERMINAL_EXEC_RE.exec(raw)
  var prefix = (m ? raw.slice(0, m.index) : raw).trim()
  if (cmd === "") return prefix
  return (prefix === "" ? "" : prefix + " ")
    + "-e " + TERMINAL_SHELL + " " + TERMINAL_SHELL_FLAG + " "
    + shellQuoteToken(withKeepOpen(cmd))
}

// The second line under an application's name: what makes this Foot the one
// running btop rather than any other Foot. Arguments say more than a folder,
// so they win when a window has both.
function applicationDetail(app) {
  if (!isPlainObject(app)) return ""
  var args = asString(app.args, "").trim()
  if (args !== "") return args
  return prettyDirectory(app.directory)
}

// The whole command line an application would run, as one string, for the
// import preview and the log. Not for a shell: nothing here is quoted.
function applicationRunLine(app) {
  if (!isPlainObject(app)) return ""
  var head = app.desktopId ? String(app.desktopId) + ".desktop" : String(app.command || "")
  if (head === "") return ""
  var args = asString(app.args, "").trim()
  var line = args === "" ? head : head + " " + args
  var dir = prettyDirectory(app.directory)
  return dir === "" ? line : line + "  (in " + dir + ")"
}

// ------------------------------------------------------------ pane layouts
//
// A workspace layout is a binary split tree. A leaf is one pane and names at
// most one application; a split holds two children side by side (`row`) or
// stacked (`column`), with `ratio` as the first child's share. The tree is
// what the editor draws and drags around.
//
// `applications` stays the flat launch list, and reconcileLayouts keeps the
// two in step: every application sits in exactly one pane, its `workspace`
// comes from the layout that pane belongs to, and the launch order is the
// order the panes read in. That way nothing downstream of the editor —
// activationPlan, the CLI, an export — has to know panes exist.

var MAX_LAYOUTS = 24
var MAX_PANES = 32
var MAX_SPLIT_DEPTH = 6
var MIN_RATIO = 0.1
var MAX_RATIO = 0.9
var UID_PATTERN = /^[A-Za-z0-9_-]{1,24}$/

function clampRatio(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0.5
  if (n < MIN_RATIO) return MIN_RATIO
  if (n > MAX_RATIO) return MAX_RATIO
  return n
}

function paneLeaf(uid) {
  return { app: asString(uid, "") }
}

function paneSplitNode(direction, first, second, ratio) {
  return {
    split: direction === "column" ? "column" : "row",
    ratio: clampRatio(ratio),
    children: [first, second]
  }
}

function isPaneSplit(node) {
  return isPlainObject(node) && Array.isArray(node.children) && node.children.length === 2
}

// A path names a node by the turns taken from the root: "" is the root, "01"
// is the second child of the first child. One character per level, so it is
// also a stable identity for a delegate and cheap to compare.
function paneAt(tree, path) {
  var node = tree
  var p = String(path === null || path === undefined ? "" : path)
  for (var i = 0; i < p.length; i++) {
    if (!isPaneSplit(node)) return null
    node = node.children[p.charAt(i) === "0" ? 0 : 1]
  }
  return isPlainObject(node) ? node : null
}

function paneReplaceAt(tree, path, next) {
  var p = String(path === null || path === undefined ? "" : path)
  if (p === "") return next
  var root = clone(tree)
  var node = root
  for (var i = 0; i < p.length - 1; i++) {
    if (!isPaneSplit(node)) return tree
    node = node.children[p.charAt(i) === "0" ? 0 : 1]
  }
  if (!isPaneSplit(node)) return tree
  node.children[p.charAt(p.length - 1) === "0" ? 0 : 1] = next
  return root
}

function paneCount(node) {
  if (!isPaneSplit(node)) return 1
  return paneCount(node.children[0]) + paneCount(node.children[1])
}

// Depth-first, which is also reading order: left before right, top before
// bottom. Launch order follows it, so what you see is the order things start.
function paneApps(node, out) {
  var list = Array.isArray(out) ? out : []
  if (!isPaneSplit(node)) {
    var uid = asString(node && node.app, "")
    if (uid !== "") list.push(uid)
    return list
  }
  paneApps(node.children[0], list)
  paneApps(node.children[1], list)
  return list
}

function paneFindApp(node, uid, path) {
  var want = asString(uid, "")
  if (want === "") return null
  var here = String(path === null || path === undefined ? "" : path)
  if (!isPaneSplit(node)) return asString(node && node.app, "") === want ? here : null
  return paneFindApp(node.children[0], want, here + "0")
    || paneFindApp(node.children[1], want, here + "1")
}

// The first empty pane in reading order, or null when every pane is taken.
function paneFirstEmpty(node, path) {
  var here = String(path === null || path === undefined ? "" : path)
  if (!isPaneSplit(node)) return asString(node && node.app, "") === "" ? here : null
  return paneFirstEmpty(node.children[0], here + "0")
    || paneFirstEmpty(node.children[1], here + "1")
}

function paneLastLeaf(node, path) {
  var here = String(path === null || path === undefined ? "" : path)
  if (!isPaneSplit(node)) return here
  return paneLastLeaf(node.children[1], here + "1")
}

function paneSplitAt(tree, path, direction) {
  var node = paneAt(tree, path)
  if (!isPlainObject(node) || isPaneSplit(node)) return tree
  if (String(path || "").length >= MAX_SPLIT_DEPTH) return tree
  if (paneCount(tree) >= MAX_PANES) return tree
  return paneReplaceAt(tree, path,
    paneSplitNode(direction, paneLeaf(node.app), paneLeaf(""), 0.5))
}

// Removing a pane promotes its sibling into the parent's place, which is what
// a tiling window manager does when a window closes, and keeps the tree from
// growing single-child splits it has no way to draw.
function paneRemoveAt(tree, path) {
  var p = String(path === null || path === undefined ? "" : path)
  if (p === "") return paneLeaf("")
  var parentPath = p.slice(0, -1)
  var parent = paneAt(tree, parentPath)
  if (!isPaneSplit(parent)) return tree
  return paneReplaceAt(tree, parentPath, clone(parent.children[p.charAt(p.length - 1) === "0" ? 1 : 0]))
}

function paneSetAppAt(tree, path, uid) {
  var node = paneAt(tree, path)
  if (!isPlainObject(node) || isPaneSplit(node)) return tree
  return paneReplaceAt(tree, path, paneLeaf(uid))
}

function paneSetRatioAt(tree, path, ratio) {
  var node = paneAt(tree, path)
  if (!isPaneSplit(node)) return tree
  var next = clone(node)
  next.ratio = clampRatio(ratio)
  return paneReplaceAt(tree, path, next)
}

// Adds an application without being told where: it fills the first empty pane,
// and splits the last one when there is none. The direction alternates with
// depth so a list of applications lands as a grid rather than a row of slivers.
// Returns the tree unchanged once the pane budget is spent.
function paneAppend(tree, uid) {
  var empty = paneFirstEmpty(tree, "")
  if (empty !== null) return paneSetAppAt(tree, empty, uid)
  var last = paneLastLeaf(tree, "")
  var split = paneSplitAt(tree, last, last.length % 2 === 0 ? "row" : "column")
  if (split === tree) return tree
  return paneSetAppAt(split, last + "1", uid)
}

function paneRemoveApp(tree, uid) {
  var path = paneFindApp(tree, uid, "")
  if (path === null) return tree
  return paneRemoveAt(tree, path)
}

// Geometry for one tree. Everything the canvas draws comes from here, so the
// hit testing, the dividers, and the panes cannot drift apart. `gap` is the
// divider thickness and is taken out of the split, not added around it, so the
// rectangles always add up to the size handed in.
function paneRects(tree, width, height, gap) {
  var out = { panes: [], dividers: [] }
  var g = Number(gap)
  if (!isFinite(g) || g < 0) g = 0
  var w = Math.max(0, Number(width) || 0)
  var h = Math.max(0, Number(height) || 0)
  collectPaneRects(isPlainObject(tree) ? tree : paneLeaf(""), 0, 0, w, h, g, "", out)
  return out
}

function collectPaneRects(node, x, y, w, h, gap, path, out) {
  if (!isPaneSplit(node)) {
    out.panes.push({
      path: path, app: asString(node && node.app, ""),
      x: x, y: y, width: w, height: h
    })
    return
  }
  var ratio = clampRatio(node.ratio)
  if (node.split === "column") {
    var top = Math.max(0, (h - gap) * ratio)
    collectPaneRects(node.children[0], x, y, w, top, gap, path + "0", out)
    out.dividers.push({
      path: path, direction: "column",
      x: x, y: y + top, width: w, height: gap,
      spanX: x, spanY: y, spanWidth: w, spanHeight: h
    })
    collectPaneRects(node.children[1], x, y + top + gap, w, Math.max(0, h - gap - top), gap, path + "1", out)
    return
  }
  var left = Math.max(0, (w - gap) * ratio)
  collectPaneRects(node.children[0], x, y, left, h, gap, path + "0", out)
  out.dividers.push({
    path: path, direction: "row",
    x: x + left, y: y, width: gap, height: h,
    spanX: x, spanY: y, spanWidth: w, spanHeight: h
  })
  collectPaneRects(node.children[1], x + left + gap, y, Math.max(0, w - gap - left), h, gap, path + "1", out)
}

function normalizePaneNode(raw, depth, budget) {
  if (!isPlainObject(raw)) return paneLeaf("")
  if (isPaneSplit(raw) && depth < MAX_SPLIT_DEPTH && budget.panes < MAX_PANES) {
    // A split turns one pane into two, so it costs one against the budget.
    budget.panes++
    var first = normalizePaneNode(raw.children[0], depth + 1, budget)
    var second = normalizePaneNode(raw.children[1], depth + 1, budget)
    return paneSplitNode(raw.split, first, second, raw.ratio)
  }
  var uid = asString(raw.app, "").trim()
  return paneLeaf(UID_PATTERN.test(uid) ? uid : "")
}

// A layout's workspace is either a reference Hyprland can name or "", which
// means "wherever you are". A workspace that is neither is not a workspace,
// so the layout it labels is dropped rather than silently retargeted.
function normalizeLayouts(raw) {
  var list = Array.isArray(raw) ? raw : []
  var limit = list.length < MAX_LAYOUTS ? list.length : MAX_LAYOUTS
  var seen = Object.create(null)
  var out = []
  for (var i = 0; i < limit; i++) {
    var item = isPlainObject(list[i]) ? list[i] : {}
    var target = item.workspace
    var ws = ""
    if (target !== null && target !== undefined && String(target) !== "") {
      ws = workspaceRef(target)
      if (ws === "") continue
    }
    if (seen["w:" + ws]) continue
    seen["w:" + ws] = true
    out.push({ workspace: ws, tree: normalizePaneNode(item.tree, 0, { panes: 1 }) })
  }
  return out
}

// A numbered tab is a position, not a label. Drag the second workspace to the
// front and the strip still reads 1, 2, 3 across — what moved is everything
// inside it, which is the thing you were dragging. A tab the user named keeps
// that name wherever it lands, because a name is a label and does travel.
//
// Only plain digits count as positional. `project`, `name:Deep Work`,
// `special:magic`, a relative step, and the blank "anywhere" tab are all names
// and are left exactly as they are.
function renumberLayouts(layouts) {
  var out = Array.isArray(layouts) ? clone(layouts) : []
  var position = 0
  for (var i = 0; i < out.length; i++) {
    if (!/^\d+$/.test(String(out[i].workspace))) continue
    position++
    out[i].workspace = String(position)
  }
  return out
}

function paneUid(taken) {
  var n = 1
  while (taken["p" + n]) n++
  return "p" + n
}

// Every application carries a uid so a pane can name it across a reorder. One
// is minted here for anything that arrives without a usable one — an import, a
// capture, or a config written by hand.
function assignApplicationUids(apps) {
  var taken = Object.create(null)
  var i
  for (i = 0; i < apps.length; i++) {
    var have = asString(apps[i].uid, "")
    if (UID_PATTERN.test(have) && !taken[have]) taken[have] = true
    else apps[i].uid = ""
  }
  for (i = 0; i < apps.length; i++) {
    if (apps[i].uid !== "") continue
    var fresh = paneUid(taken)
    taken[fresh] = true
    apps[i].uid = fresh
  }
  return apps
}

function freshApplicationUid(apps) {
  var taken = Object.create(null)
  var list = Array.isArray(apps) ? apps : []
  for (var i = 0; i < list.length; i++) {
    var uid = asString(list[i] && list[i].uid, "")
    if (uid !== "") taken[uid] = true
  }
  return paneUid(taken)
}

// The one place where panes and applications are made to agree. Called on
// every normalize and after every edit in the editor, so neither side can be
// read while the other is half-updated.
function reconcileLayouts(applications, layouts) {
  var apps = Array.isArray(applications) ? applications : []
  var known = Object.create(null)
  var placed = Object.create(null)
  var i
  for (i = 0; i < apps.length; i++) known["u:" + apps[i].uid] = apps[i]

  // Pass one: a pane may only name an application that exists, and only once.
  // Anything else is emptied rather than dropped, so the shape survives.
  var out = []
  var source = Array.isArray(layouts) ? layouts : []
  for (i = 0; i < source.length; i++)
    out.push({ workspace: source[i].workspace, tree: claimPanes(source[i].tree, known, placed) })

  // Pass two: an application no pane claimed joins the layout for the
  // workspace it already names, which is how a captured or imported mode
  // arrives with a layout it never stored.
  for (i = 0; i < apps.length; i++) {
    if (placed["u:" + apps[i].uid]) continue
    var ws = apps[i].workspace === null || apps[i].workspace === undefined
      ? "" : workspaceRef(apps[i].workspace)
    var layout = null
    for (var k = 0; k < out.length; k++) if (out[k].workspace === ws) { layout = out[k]; break }
    if (!layout) {
      if (out.length >= MAX_LAYOUTS) continue
      layout = { workspace: ws, tree: paneLeaf("") }
      out.push(layout)
    }
    var grown = paneAppend(layout.tree, apps[i].uid)
    if (grown === layout.tree) continue
    layout.tree = grown
    placed["u:" + apps[i].uid] = true
  }

  // A mode with nothing in it still needs somewhere to drop the first thing,
  // and that somewhere is workspace 1. "Anywhere" is a real answer — it is
  // what an application with no workspace of its own gets, and it is kept the
  // moment anything is in it — but it is a poor first one: an empty tab
  // labelled "anywhere" says nothing that an empty mode did not already say.
  if (out.length === 0) out.push({ workspace: "1", tree: paneLeaf("") })
  else if (apps.length === 0 && out.length === 1 && out[0].workspace === "")
    out[0].workspace = "1"

  // Pass three: the layout an application ended up in is its workspace, and
  // the order the panes read in is the order it launches in.
  var ordered = []
  for (i = 0; i < out.length; i++) {
    var uids = paneApps(out[i].tree, [])
    for (var u = 0; u < uids.length; u++) {
      var app = known["u:" + uids[u]]
      if (!app) continue
      // Back through asWorkspace so a numeric workspace stays a number, the
      // shape everything downstream of normalizeApplication already reads.
      app.workspace = asWorkspace(out[i].workspace)
      ordered.push(app)
    }
  }
  // An application the pane budget could not take keeps the workspace it had.
  for (i = 0; i < apps.length; i++)
    if (!placed["u:" + apps[i].uid]) ordered.push(apps[i])

  return { applications: ordered, layouts: out }
}

function claimPanes(node, known, placed) {
  if (!isPaneSplit(node)) {
    var uid = asString(node && node.app, "")
    if (uid === "" || !known["u:" + uid] || placed["u:" + uid]) return paneLeaf("")
    placed["u:" + uid] = true
    return paneLeaf(uid)
  }
  return paneSplitNode(node.split,
    claimPanes(node.children[0], known, placed),
    claimPanes(node.children[1], known, placed),
    node.ratio)
}

// Reconciles a mode in place-ish: returns a copy with `applications` and
// `workspaces.layouts` agreeing. The editor calls this after every pane edit
// so the draft it draws is the draft it would save.
function reconcileMode(mode) {
  if (!isPlainObject(mode)) return mode
  var next = clone(mode)
  var apps = Array.isArray(next.applications) ? next.applications : []
  assignApplicationUids(apps)
  if (!isPlainObject(next.workspaces)) next.workspaces = { target: null, layouts: [] }
  var settled = reconcileLayouts(apps, next.workspaces.layouts)
  next.applications = settled.applications
  next.workspaces.layouts = settled.layouts
  return next
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

  // Cardinality is capped here, before anything is cloned or rendered. A mode
  // with a million applications is not a mode anyone wrote.
  var apps = Array.isArray(raw.applications) ? raw.applications : []
  var appLimit = apps.length < MAX_APPLICATIONS ? apps.length : MAX_APPLICATIONS
  for (var i = 0; i < appLimit; i++) {
    var app = normalizeApplication(apps[i])
    if (app) ctx.applications.push(app)
  }

  // Panes last, once the applications they name are known and capped. A mode
  // that never stored a layout gets one derived from the workspace each of its
  // applications already asked for.
  assignApplicationUids(ctx.applications)
  var settled = reconcileLayouts(ctx.applications, normalizeLayouts(workspaces.layouts))
  ctx.applications = settled.applications
  ctx.workspaces.layouts = settled.layouts

  var commands = isPlainObject(raw.commands) ? raw.commands : {}
  ctx.commands.onActivate = asStringList(commands.onActivate, MAX_HOOKS, MAX_COMMAND)
  ctx.commands.onDeactivate = asStringList(commands.onDeactivate, MAX_HOOKS, MAX_COMMAND)

  var triggers = Array.isArray(raw.triggers) ? raw.triggers : []
  var triggerLimit = triggers.length < MAX_TRIGGERS ? triggers.length : MAX_TRIGGERS
  for (var t = 0; t < triggerLimit; t++) {
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

  // The same ceiling the import path applies. A config is a document that
  // arrives from disk, so it gets the document limits too — enforced before
  // normalizing, which is where the allocation happens.
  if (list.length > MAX_MODES) {
    warnings.push("Config held " + list.length + " modes; kept the first " + MAX_MODES + ".")
    list = list.slice(0, MAX_MODES)
  }

  var ids = []
  var dropped = 0
  for (var i = 0; i < list.length; i++) {
    var ctx = normalizeMode(list[i], ids)
    if (!ctx) {
      dropped++
      continue
    }
    ids.push(ctx.id)
    config.modes.push(ctx)
  }
  // One line, not one per entry: a file of unreadable entries would otherwise
  // turn a bounded document into an unbounded list of warnings.
  if (dropped > 0) warnings.push("Dropped " + dropped + " mode entr" + (dropped === 1 ? "y" : "ies") + " that could not be read.")

  var active = asString(raw.activeMode, "").trim()
  config.activeMode = (active !== "" && ids.indexOf(active) !== -1) ? active : null
  if (active !== "" && config.activeMode === null)
    warnings.push("Active mode \"" + active + "\" no longer exists; cleared.")

  return { config: config, warnings: warnings }
}

function parseConfig(text) {
  // Not asString: that clamps to MAX_STRING, which is a field ceiling, and a
  // whole document is not a field. The document ceiling is enforced by the
  // reader before this ever sees it, and again here.
  var input = typeof text === "string" ? text : ""
  if (input.length > MAX_IMPORT_BYTES)
    return {
      config: defaultConfig(),
      warnings: ["wsmodes.json is larger than " + MAX_IMPORT_BYTES + " bytes; started from defaults"],
      recovered: true,
      firstRun: false
    }
  var raw = input.trim()
  if (raw === "") return { config: defaultConfig(), warnings: [], recovered: false, firstRun: true }
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return {
      config: defaultConfig(),
      warnings: ["wsmodes.json is not valid JSON (" + (e && e.message ? e.message : "parse error") + "). Using defaults; the file was left untouched."],
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
      var detail = applicationDetail(apps[i])
      steps.push({
        kind: "applications",
        label: "Launch " + applicationLabel(apps[i])
          + (detail === "" ? "" : " " + detail)
          + (workspace === null ? "" : " on workspace " + workspace),
        value: apps[i].command || "",
        desktopId: apps[i].desktopId || "",
        args: apps[i].args || "",
        directory: apps[i].directory || "",
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
    var line = applicationRunLine(apps[i])
    if (line !== "") out.push("app  " + line)
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
  return { version: SCHEMA_VERSION, kind: "wsmodes-export", modes: out }
}

function parseImport(text) {
  // Bounded before JSON.parse, not after: parsing is where the memory goes.
  var input = typeof text === "string" ? text : ""
  if (input.length > MAX_IMPORT_BYTES)
    return { modes: [], error: "The file is larger than " + MAX_IMPORT_BYTES + " bytes." }
  var raw = input.trim()
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

  if (list.length > MAX_MODES)
    return { modes: [], error: "The file holds more than " + MAX_MODES + " modes." }

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

// A closed record: four known keys, and nothing the output can add to them.
// `missing` is null-prototype because the lookup is `missing[name] === true` —
// on a plain object a command called `toString` or `valueOf` would come back
// truthy off the prototype chain and be reported as not installed.
// A process's argv arrives with its NUL separators turned into unit
// separators, because an argument is allowed to contain a space and the line
// it rides on is split by tabs.
var PROC_ARG_SEPARATOR = "\u001f"

function parseProbeOutput(text) {
  var out = { wallpaper: "", theme: "", missing: Object.create(null), processes: Object.create(null) }
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
    else if (parts[0] === "PROC") {
      var pid = probeField(parts[1])
      if (pid === "" || !/^[0-9]{1,10}$/.test(pid)) continue
      var argv = []
      var words = probeField(parts[3] || "").split(PROC_ARG_SEPARATOR)
      for (var w = 0; w < words.length && w < PROBE_MAX_ITEMS; w++)
        if (words[w] !== "") argv.push(words[w])
      out.processes[pid] = { cwd: probeField(parts[2]), argv: argv }
    }
  }
  return out
}

// The guarded reader and writer answer on one line, then the body. The verdict
// is a closed set: anything else is refused rather than guessed at.
function parseFileResult(text, limit) {
  var raw = typeof text === "string" ? text : ""
  var cap = typeof limit === "number" && limit > 0 ? limit : PROBE_MAX_BYTES
  var newline = raw.indexOf("\n")
  if (newline === -1) return { verdict: "", detail: "", content: "" }

  var parts = raw.slice(0, newline).split("\t")
  if (parts[0] !== "RESULT") return { verdict: "", detail: "", content: "" }
  var verdict = probeField(parts[1])
  if (verdict !== "ok" && verdict !== "absent" && verdict !== "refuse")
    return { verdict: "", detail: "", content: "" }

  var content = raw.slice(newline + 1)
  if (content.length > cap) content = content.slice(0, cap)
  return { verdict: verdict, detail: probeField(parts[2]), content: content }
}

function emptyProbeResult() {
  return { wallpaper: "", theme: "", missing: Object.create(null), processes: Object.create(null) }
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

// Everything after one of these is the command the terminal was told to run,
// which is the whole point of capturing that window rather than a bare shell.
var TERMINAL_EXEC_FLAGS = ["-e", "-x", "--command", "--execute"]

// Paths under these belong to the program, not to you: an Electron app is
// launched with its own bundle as an argument, and `code /usr/lib/code/out/
// main.js` is not a thing anyone meant to write down.
var SYSTEM_PATH_PREFIXES = ["/usr/", "/opt/", "/nix/", "/snap/", "/run/", "/app/", "/var/lib/flatpak/"]

function looksLikeUrl(token) {
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(token)
}

function looksLikePath(token) {
  return token.charAt(0) === "/" || token.indexOf("~/") === 0 || token.indexOf("./") === 0
}

function isSystemPath(token) {
  for (var i = 0; i < SYSTEM_PATH_PREFIXES.length; i++)
    if (token.indexOf(SYSTEM_PATH_PREFIXES[i]) === 0) return true
  return false
}

// Reduce a real /proc command line to the part worth putting in a mode.
//
// A window's argv is mostly what its launcher decided — session ids, ozone
// flags, a renderer's own bundle path. What a person would recognise is the
// document, the URL, or the command a terminal was handed. So: drop argv[0]
// and every flag, keep URLs, keep paths that are not the program's own, keep
// bare positional words, and keep the entire tail once a terminal exec flag
// says the rest is a command line of its own.
function captureArguments(argv, home) {
  var list = Array.isArray(argv) ? argv : []
  var kept = []
  for (var i = 1; i < list.length; i++) {
    var token = asString(list[i], "").trim()
    if (token === "" || token === "--") continue

    if (TERMINAL_EXEC_FLAGS.indexOf(token) !== -1) {
      // The flag and everything after it, verbatim: this is a command, and a
      // command's own flags are not ours to filter.
      for (var t = i; t < list.length; t++) {
        var tail = asString(list[t], "").trim()
        if (tail !== "") kept.push(tail)
      }
      break
    }

    if (token.charAt(0) === "-") continue
    if (looksLikeUrl(token)) { kept.push(token); continue }
    if (looksLikePath(token)) {
      if (isSystemPath(token)) continue
      kept.push(collapseHome(token, home))
      continue
    }
    kept.push(token)
  }
  return kept.join(" ").slice(0, MAX_ARGS)
}

// Your home directory is where everything starts, so recording it says
// nothing. Anywhere else is the folder you actually opened this in.
function captureDirectory(cwd, home) {
  var dir = prettyDirectory(cwd)
  if (dir === "" || dir === "/") return ""
  var collapsed = collapseHome(dir, home)
  if (collapsed === "~" || collapsed === "") return ""
  return collapsed.slice(0, MAX_DIRECTORY)
}

// Shape a snapshot of the running desktop into mode fields. Takes plain
// data so it stays testable; the caller gathers it from Hyprland/PipeWire.
//
// state: { name, description, workspace, dnd, audioOutput, wallpaper, theme,
//          windows: [{ desktopId, command, workspace, title, args, directory }] }
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
      args: w.args,
      directory: w.directory,
      workspace: w.workspace,
      note: w.title,
      enabled: true
    })
    if (!app) continue
    // Three terminals on one workspace are one entry, not three — but a
    // terminal running btop and a terminal sitting in ~/Projects are two
    // different things to open, so what they run is part of what they are.
    var key = (app.desktopId || app.command) + " " + app.args + " " + app.directory
      + "@" + String(app.workspace)
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
  splitVertical: "\u{f0bcc}",
  splitHorizontal: "\u{f0bcb}",
  landing: "\u{f023b}",
  iconSlot: "\u{f0704}",
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
    applicationDetail: applicationDetail,
    isTerminalCategories: isTerminalCategories,
    terminalCommandOf: terminalCommandOf,
    setTerminalCommand: setTerminalCommand,
    applicationRunLine: applicationRunLine,
    prettyDirectory: prettyDirectory,
    collapseHome: collapseHome,
    expandHome: expandHome,
    MAX_LAYOUTS: MAX_LAYOUTS,
    MAX_PANES: MAX_PANES,
    MAX_SPLIT_DEPTH: MAX_SPLIT_DEPTH,
    clampRatio: clampRatio,
    paneLeaf: paneLeaf,
    isPaneSplit: isPaneSplit,
    paneAt: paneAt,
    paneCount: paneCount,
    paneApps: paneApps,
    paneFindApp: paneFindApp,
    paneFirstEmpty: paneFirstEmpty,
    paneSplitAt: paneSplitAt,
    paneRemoveAt: paneRemoveAt,
    paneSetAppAt: paneSetAppAt,
    paneSetRatioAt: paneSetRatioAt,
    paneAppend: paneAppend,
    paneRemoveApp: paneRemoveApp,
    paneRects: paneRects,
    normalizeLayouts: normalizeLayouts,
    renumberLayouts: renumberLayouts,
    freshApplicationUid: freshApplicationUid,
    reconcileLayouts: reconcileLayouts,
    reconcileMode: reconcileMode,
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
    PROC_ARG_SEPARATOR: PROC_ARG_SEPARATOR,
    parseFileResult: parseFileResult,
    emptyProbeResult: emptyProbeResult,
    prunePlacements: prunePlacements,
    matchPlacement: matchPlacement,
    parseOpenWindowEvent: parseOpenWindowEvent,
    triggerMatches: triggerMatches,
    evaluateTrigger: evaluateTrigger,
    captureMode: captureMode,
    captureArguments: captureArguments,
    captureDirectory: captureDirectory,
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

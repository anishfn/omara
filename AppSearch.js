// Ranking and filtering for the installed-application list.
//
// This is the plugin's own copy of the ordering the shell's launcher uses,
// and it is deliberately the same ordering: the list in the editor's sidebar
// and the list in the Omarchy menu are showing the same applications, and a
// person who has learned that typing "ff" reaches Firefox in one should not
// have to learn something else in the other.

function entryName(entry) {
  return String((entry && entry.name) || (entry && entry.id) || "")
}

function entrySubtext(entry) {
  return String((entry && entry.genericName) || "")
}

function entrySortKey(entry) {
  return entryName(entry).toLowerCase()
}

function keywordText(entry) {
  try {
    if (entry && entry.keywords && typeof entry.keywords.join === "function")
      return entry.keywords.join(" ")
  } catch (e) {}
  return ""
}

function entrySearchText(entry) {
  if (!entry) return ""
  return [entry.name, entry.genericName, entry.comment, keywordText(entry), entry.id]
    .join(" ").toLowerCase()
}

// "GIMPImageEditor" is three words, and so is "gimp-image.editor". Splitting on
// the case change as well as the punctuation is what makes an acronym match
// find either of them.
function wordText(value) {
  return String(value || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[._:/\\-]+/g, " ")
    .toLowerCase()
}

function words(value) {
  var parts = wordText(value).split(/[^a-z0-9]+/)
  var out = []
  for (var i = 0; i < parts.length; i++) if (parts[i]) out.push(parts[i])
  return out
}

function entryAcronym(entry) {
  var parts = words([entry && entry.name, entry && entry.genericName,
    keywordText(entry), entry && entry.id].join(" "))
  var out = ""
  for (var i = 0; i < parts.length; i++) out += parts[i].charAt(0)
  return out
}

function termMatches(entry, term) {
  if (!term) return true
  var name = entryName(entry).toLowerCase()
  var id = String((entry && entry.id) || "").toLowerCase()
  if (name.indexOf(term) >= 0) return true
  if (id.indexOf(term) >= 0) return true
  if (entrySearchText(entry).indexOf(term) >= 0) return true
  // An acronym match on a long term is more often a coincidence than an
  // intention, so only short ones are offered it.
  return term.length <= 5 && entryAcronym(entry).indexOf(term) >= 0
}

function allTermsMatch(entry, query) {
  var terms = String(query || "").toLowerCase().trim().split(/\s+/)
  for (var i = 0; i < terms.length; i++)
    if (terms[i] && !termMatches(entry, terms[i])) return false
  return true
}

function fuzzyScore(entry, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return 0
  if (!allTermsMatch(entry, q)) return -1

  var name = entryName(entry).toLowerCase()
  var id = String((entry && entry.id) || "").toLowerCase()
  var haystack = entrySearchText(entry)
  var directName = name.indexOf(q)
  var directId = id.indexOf(q)
  if (directName === 0) return 10000 - name.length
  if (directId === 0) return 9500 - id.length
  if (directName > 0) return 8000 - directName * 10 - name.length
  if (directId > 0) return 7600 - directId * 10 - id.length

  var hayIndex = haystack.indexOf(q)
  if (hayIndex >= 0) return 6000 - hayIndex

  var acronym = entryAcronym(entry)
  var acronymIndex = acronym.indexOf(q)
  if (acronymIndex === 0) return 5000 - acronym.length
  if (acronymIndex > 0) return 4600 - acronymIndex * 10 - acronym.length

  return 4000 - name.length
}

// Rows, not entries: the delegates read `modelData.entry`, and carrying the
// score alongside is what lets the sort be stable on name when there is no
// query to rank by.
function sortedEntries(values, query, hiddenCallback) {
  var q = String(query || "").trim()
  var rows = []

  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    if (!entry || entry.noDisplay) continue
    if (hiddenCallback && hiddenCallback(entry)) continue
    var name = entryName(entry)
    if (!name) continue
    var score = fuzzyScore(entry, q)
    if (score < 0) continue
    rows.push({ entry: entry, score: score, key: entrySortKey(entry), name: name.toLowerCase() })
  }

  rows.sort(function(a, b) {
    if (q && a.score !== b.score) return b.score - a.score
    if (a.key < b.key) return -1
    if (a.key > b.key) return 1
    if (a.name < b.name) return -1
    if (a.name > b.name) return 1
    return 0
  })

  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    entryName: entryName,
    entrySubtext: entrySubtext,
    entrySortKey: entrySortKey,
    entrySearchText: entrySearchText,
    entryAcronym: entryAcronym,
    fuzzyScore: fuzzyScore,
    sortedEntries: sortedEntries
  }
}

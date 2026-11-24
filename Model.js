.pragma library

var STEPS = [
  { id: "orphans",      icon: "󰏗", needsRoot: true,  defaultEnabled: true },
  { id: "pacman_cache", icon: "󱘥", needsRoot: true,  defaultEnabled: true },
  { id: "aur_cache",    icon: "󰆸", needsRoot: true,  defaultEnabled: true },
  { id: "journal",      icon: "󰈙", needsRoot: true,  defaultEnabled: true },
  { id: "user_cache",   icon: "󰩺", needsRoot: false, defaultEnabled: true },
  { id: "dns_cache",    icon: "󱞖", needsRoot: true,  defaultEnabled: true },
  { id: "ram_swap",     icon: "󰍛", needsRoot: true,  defaultEnabled: true },
  { id: "pacnew",       icon: "󱁼", needsRoot: true,  defaultEnabled: true }
]

var STEP_IDS = {}
for (var _i = 0; _i < STEPS.length; _i++) {
  STEP_IDS[STEPS[_i].id] = true
}

var MAX_LOG_LINES = 200
var MAX_LINE_LENGTH = 240

function defaultSelection() {
  var map = {}
  for (var i = 0; i < STEPS.length; i++) {
    map[STEPS[i].id] = STEPS[i].defaultEnabled
  }
  return map
}

function defaultStatuses() {
  var map = {}
  for (var i = 0; i < STEPS.length; i++) {
    map[STEPS[i].id] = "idle"
  }
  return map
}

function selectedStepIds(selectionMap) {
  var out = []
  var sel = selectionMap || {}
  for (var i = 0; i < STEPS.length; i++) {
    if (sel[STEPS[i].id] === true) out.push(STEPS[i].id)
  }
  return out
}

function selectionNeedsRoot(selectionMap) {
  var sel = selectionMap || {}
  for (var i = 0; i < STEPS.length; i++) {
    if (sel[STEPS[i].id] === true && STEPS[i].needsRoot) return true
  }
  return false
}

// Neutralize markup-like characters and control bytes before passing dynamic
// text to any shared tooltip or notification sink.
function sanitizeText(value, maxLen) {
  var limit = maxLen > 0 ? maxLen : MAX_LINE_LENGTH
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "")
  s = s.replace(/[<>]/g, "")
  s = s.replace(/\s+/g, " ").trim()
  if (s.length > limit) s = s.slice(0, limit - 1) + "…"
  return s
}

function clampNonNegativeInt(raw, maxValue) {
  var n = parseInt(String(raw || "0"), 10)
  if (!isFinite(n) || n < 0) return 0
  if (maxValue !== undefined && n > maxValue) return maxValue
  return n
}

function formatBytes(bytes, formatNumberFn) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "0 B"
  var fmt = typeof formatNumberFn === "function"
    ? formatNumberFn
    : function(v, d) { return d > 0 ? v.toFixed(d) : String(Math.round(v)) }

  var units = ["B", "KB", "MB", "GB", "TB"]
  var idx = 0
  var val = n
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024
    idx++
  }
  var decimals = idx === 0 ? 0 : (val >= 100 ? 0 : (val >= 10 ? 1 : 2))
  return fmt(val, decimals) + " " + units[idx]
}

function parseScanOutput(raw) {
  var info = {
    scanned: false,
    orphansCount: 0,
    pacmanCacheBytes: 0,
    aurCacheBytes: 0,
    journalBytes: 0,
    userCacheBytes: 0,
    pacnewCount: 0,
    totalBytes: 0
  }
  var lines = String(raw || "").split("\n")
  var seenAny = false
  for (var i = 0; i < lines.length && i < 64; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq).trim()
    var val = line.slice(eq + 1).trim()
    if (key === "orphans_count") {
      info.orphansCount = clampNonNegativeInt(val, 100000)
      seenAny = true
    } else if (key === "pacman_cache_bytes") {
      info.pacmanCacheBytes = clampNonNegativeInt(val)
      seenAny = true
    } else if (key === "aur_cache_bytes") {
      info.aurCacheBytes = clampNonNegativeInt(val)
      seenAny = true
    } else if (key === "journal_bytes") {
      info.journalBytes = clampNonNegativeInt(val)
      seenAny = true
    } else if (key === "user_cache_bytes") {
      info.userCacheBytes = clampNonNegativeInt(val)
      seenAny = true
    } else if (key === "pacnew_count") {
      info.pacnewCount = clampNonNegativeInt(val, 100000)
      seenAny = true
    }
  }
  info.totalBytes = info.pacmanCacheBytes + info.aurCacheBytes + info.journalBytes + info.userCacheBytes
  info.scanned = seenAny
  return info
}

function parseRunnerLine(rawLine) {
  var line = String(rawLine === undefined || rawLine === null ? "" : rawLine).replace(/\r$/, "")
  if (!line) return { kind: "empty" }

  if (line.indexOf("@@STEP:") === 0) {
    var parts = line.slice(7).split(":")
    var stepId = parts[0] || ""
    var status = parts[1] || ""
    var detail = parts.slice(2).join(":")
    if (!STEP_IDS[stepId]) return { kind: "ignore" }
    return {
      kind: "step",
      stepId: stepId,
      status: status,
      detail: sanitizeText(detail, 120)
    }
  }

  if (line.indexOf("@@PROGRESS:") === 0) {
    var pct = clampNonNegativeInt(line.slice(11), 100)
    return { kind: "progress", percent: pct }
  }

  if (line === "@@AUTH_CANCELLED") {
    return { kind: "auth_cancelled" }
  }

  if (line.indexOf("@@LOG:") === 0) {
    return { kind: "log", text: sanitizeText(line.slice(6), MAX_LINE_LENGTH) }
  }

  return { kind: "log", text: sanitizeText(line, MAX_LINE_LENGTH) }
}

function appendLogLine(lines, text) {
  var clean = sanitizeText(text, MAX_LINE_LENGTH)
  if (!clean) return lines || []
  var next = (lines || []).slice()
  next.push(clean)
  if (next.length > MAX_LOG_LINES) {
    next = next.slice(next.length - MAX_LOG_LINES)
  }
  return next
}

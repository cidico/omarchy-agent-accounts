import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.cidico.agent-accounts"
  ipcTarget: "io.github.cidico.agent-accounts"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  // ------------------------------------------------------------ accounts
  //
  // A provider whose record carries accounts (Claude, through this plugin's
  // collector) gets the decision-first view: which account to spend now, one
  // tile per account, the pace of each weekly window, and tokens per day.

  readonly property color accent: Color.accent
  // "In use" reads blue-grey beside the theme's accent: foreground pulled toward steel.
  readonly property color secondary: Qt.tint(foreground, Qt.rgba(0.45, 0.62, 0.82, 0.45))
  // Light, warm mark for "where linear pace would put you".
  readonly property color paceMark: Qt.tint("#ffffff", Qt.rgba(accent.r, accent.g, accent.b, 0.4))
  readonly property color faint: Qt.darker(foreground, 2.1)

  readonly property bool isClaude: !!provider && (provider.accounts || []).length > 0
  readonly property var accounts: isClaude ? provider.accounts : []
  readonly property var recommendedAccount: {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].id === provider.recommended) return accounts[i]
    return accounts.length > 0 ? accounts[0] : null
  }
  // The bar icon and right click speak for the multi-account provider even
  // while another tab is selected.
  readonly property var accountsProvider: {
    for (var i = 0; i < providers.length; i++)
      if ((providers[i].accounts || []).length > 0) return providers[i]
    return null
  }
  readonly property var launchTarget: {
    var p = accountsProvider
    if (!p) return null
    for (var i = 0; i < p.accounts.length; i++)
      if (p.accounts[i].id === p.recommended) return p.accounts[i]
    return p.accounts[0]
  }

  readonly property bool alarming: (!!accountsProvider && accountsProvider.allExhausted)
    || (!isClaude && !!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Canvas wants CSS strings; a color's own alpha survives unless overridden.
  function css(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255)
      + "," + (a === undefined ? c.a : a) + ")"
  }

  function accountIndex(acc) {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].id === acc.id) return i
    return 0
  }

  // Color follows the account, not the recommendation, so the charts don't
  // swap hues when the pick flips.
  function accountColor(index) {
    var palette = [root.accent, root.secondary,
      Qt.tint(root.foreground, Qt.rgba(0.45, 0.8, 0.5, 0.45)),
      Qt.tint(root.foreground, Qt.rgba(0.8, 0.5, 0.8, 0.45))]
    return palette[index % palette.length]
  }

  function pct(f) { return Math.round(Number(f || 0) * 100) + "%" }
  function pad2(n) { return (n < 10 ? "0" : "") + n }

  function whenLabel(iso) {
    var d = new Date(String(iso || ""))
    if (!isFinite(d.getTime())) return "—"
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()] + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  }

  function msUntil(iso) {
    var t = new Date(String(iso || "")).getTime()
    return isFinite(t) ? t - root.nowMs : -1
  }

  function ageText(ms) {
    if (!(ms > 0)) return "never"
    var s = (root.nowMs - ms) / 1000
    if (s < 90) return "just now"
    if (s < 3600) return Math.round(s / 60) + " min ago"
    if (s < 172800) return Math.round(s / 3600) + "h ago"
    return Math.round(s / 86400) + "d ago"
  }

  function shortProviderName(name) { return String(name || "").replace(/ Code$/, "") }

  function sessionStarted(acc) { return !!acc && !!acc.session && String(acc.session.resetsAt || "") !== "" }

  // One quiet line per tile when its numbers can't be taken at face value.
  function accountNotice(acc) {
    if (!acc) return ""
    if (acc.authStatus === "missing") return "signed out · open to sign in"
    if (!acc.weekly)
      return "limits unavailable" + (acc.limitsFetchedAtMs > 0 ? " · last read " + ageText(acc.limitsFetchedAtMs) : "")
    if (acc.authStatus === "expired") return "sign-in expired " + ageText(acc.authExpiresAtMs) + " · opening renews it"
    if (root.nowMs - acc.limitsFetchedAtMs > 60 * 60000) return "limits read " + ageText(acc.limitsFetchedAtMs)
    return ""
  }

  function launchAccount(acc) {
    if (!acc || !Array.isArray(acc.launch) || acc.launch.length === 0) return
    Util.execArgv(["omarchy-launch-tui", "--app-id=org.omarchy.agent"].concat(acc.launch).concat(["--permission-mode", "auto"]))
    root.close()
  }

  function limitsAgeMs() {
    var newest = 0
    for (var i = 0; i < accounts.length; i++) newest = Math.max(newest, Number(accounts[i].limitsFetchedAtMs || 0))
    return newest
  }

  // "Fable weekly: P 3% · W 21%" — every model-scoped weekly window, across accounts.
  function scopedChips() {
    var byModel = {}
    var order = []
    for (var i = 0; i < accounts.length; i++) {
      var limits = accounts[i].limits || []
      for (var j = 0; j < limits.length; j++) {
        if (limits[j].kind !== "weekly_scoped") continue
        var model = String(limits[j].model || limits[j].title)
        if (!byModel[model]) { byModel[model] = []; order.push(model) }
        byModel[model].push(String(accounts[i].name || "?").charAt(0).toUpperCase() + " " + pct(limits[j].percent))
      }
    }
    var out = []
    for (var k = 0; k < order.length; k++) out.push(order[k] + " weekly: " + byModel[order[k]].join(" · "))
    return out
  }

  function reasonText() {
    if (!isClaude) return ""
    return String(provider.recommendationReason || "")
  }

  function escapeHtml(text) {
    return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // The recommended account first: it gets the solid button.
  function launchOrder() {
    var first = recommendedAccount
    var out = first ? [first] : []
    for (var i = 0; i < accounts.length; i++) if (accounts[i] !== first) out.push(accounts[i])
    return out
  }

  function windowTokensTooltip() {
    var parts = []
    for (var i = 0; i < accounts.length; i++) {
      var a = accounts[i]
      parts.push(a.name + ": " + usage.formatTokenCount(a.tokensInWindow || 0) + " this window"
        + (a.tokensPreviousWindow > 0 ? ", " + usage.formatTokenCount(a.tokensPreviousWindow) + " the window before" : ""))
    }
    return parts.join(" · ")
  }

  // ---------------------------------------------------------------- charts

  function canvasFont(bold) {
    return (bold ? "bold " : "") + Style.font.caption + "px \"" + root.fontFamily + "\""
  }

  function dashLine(ctx, x1, y1, x2, y2, dash, gap) {
    var dx = x2 - x1, dy = y2 - y1
    var length = Math.sqrt(dx * dx + dy * dy)
    if (length <= 0) return
    var ux = dx / length, uy = dy / length
    ctx.beginPath()
    for (var t = 0; t < length; t += dash + gap) {
      var end = Math.min(length, t + dash)
      ctx.moveTo(x1 + ux * t, y1 + uy * t)
      ctx.lineTo(x1 + ux * end, y1 + uy * end)
    }
    ctx.stroke()
  }

  // Used share of each account's weekly window against the share of that
  // window already gone. The diagonal is linear pace: under it, allowance is
  // left over at the reset; over it, the account runs dry first.
  function paintPace(ctx, w, h, accts) {
    ctx.reset()
    var fs = Style.font.caption
    var left = Style.space(34), right = Style.space(4), top = Style.space(12), bottom = Style.space(20)
    var pw = Math.max(1, w - left - right), ph = Math.max(1, h - top - bottom)
    function X(f) { return left + pw * root.clamp(f, 0, 1) }
    function Y(p) { return top + ph * (1 - root.clamp(p, 0, 1)) }

    ctx.font = canvasFont(false)
    ctx.textBaseline = "middle"
    ctx.lineWidth = 1
    var grid = [[0, "0"], [0.5, "50%"], [1, "100%"]]
    for (var g = 0; g < grid.length; g++) {
      ctx.strokeStyle = css(root.foreground, grid[g][0] === 0 ? 0.16 : 0.08)
      if (grid[g][0] === 0) {
        ctx.beginPath(); ctx.moveTo(left, Y(0)); ctx.lineTo(left + pw, Y(0)); ctx.stroke()
      } else {
        dashLine(ctx, left, Y(grid[g][0]), left + pw, Y(grid[g][0]), 2, 3)
      }
      ctx.fillStyle = css(root.foreground, 0.4)
      ctx.textAlign = "right"
      ctx.fillText(grid[g][1], left - Style.space(6), Y(grid[g][0]))
    }

    ctx.strokeStyle = css(root.foreground, 0.32)
    dashLine(ctx, X(0), Y(0), X(1), Y(1), 4, 4)
    ctx.fillStyle = css(root.foreground, 0.4)
    ctx.textAlign = "right"
    ctx.fillText("linear pace", X(0.7), Y(0.86))

    var labels = []
    for (var i = 0; i < accts.length; i++) {
      var a = accts[i]
      if (!a.pace || !a.weekly) continue
      var color = accountColor(i)
      var ef = a.pace.elapsedFraction
      var now = a.weekly.percent
      var pts = (a.pace.series || []).slice()
      if (pts.length === 0 || pts[0][0] > 0) pts.unshift([0, 0])
      pts.push([ef, now])

      ctx.strokeStyle = css(color)
      ctx.lineWidth = 2.5
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(X(pts[0][0]), Y(pts[0][1]))
      for (var k = 1; k < pts.length; k++) ctx.lineTo(X(pts[k][0]), Y(pts[k][1]))
      ctx.stroke()

      ctx.lineWidth = 1.5
      ctx.strokeStyle = css(color, 0.7)
      dashLine(ctx, X(ef), Y(now), X(1), Y(a.pace.projectedAtReset), 3, 4)

      ctx.fillStyle = css(color)
      ctx.strokeStyle = css(root.surface)
      ctx.lineWidth = 1.5
      ctx.beginPath()
      ctx.arc(X(ef), Y(now), Style.space(4.5), 0, Math.PI * 2)
      ctx.fill()
      ctx.stroke()

      ctx.font = canvasFont(true)
      ctx.textAlign = "center"
      ctx.fillText(pct(now), X(ef), Math.max(fs / 2, Y(now) - Style.space(12)))
      labels.push({ y: Y(a.pace.projectedAtReset) - Style.space(9), text: a.name + " → ~" + pct(a.pace.projectedAtReset), color: color })
    }

    // Projection labels at the right edge, nudged apart when they meet.
    labels.sort(function(p, q) { return p.y - q.y })
    for (var l = 0; l < labels.length; l++) {
      labels[l].y = root.clamp(labels[l].y, fs / 2, top + ph - fs / 2)
      if (l > 0 && labels[l].y - labels[l - 1].y < fs + 3) labels[l].y = labels[l - 1].y + fs + 3
      ctx.font = canvasFont(true)
      ctx.textAlign = "right"
      ctx.fillStyle = css(labels[l].color)
      ctx.fillText(labels[l].text, X(1) - Style.space(2), labels[l].y)
    }

    ctx.font = canvasFont(false)
    ctx.fillStyle = css(root.foreground, 0.4)
    ctx.textAlign = "left"
    ctx.fillText("window start", X(0), h - fs / 2 - 1)
    ctx.textAlign = "right"
    ctx.fillText("reset", X(1), h - fs / 2 - 1)
  }

  // Tokens per calendar day, one line per account, with each account's
  // weekly reset marked where it fell.
  function paintDays(ctx, w, h, accts) {
    ctx.reset()
    var fs = Style.font.caption
    var dateSet = {}
    for (var i = 0; i < accts.length; i++) {
      var days = accts[i].recentDays || []
      for (var d = 0; d < days.length; d++) dateSet[String(days[d].date)] = true
    }
    var dates = Object.keys(dateSet).sort().slice(-7)
    var n = dates.length
    if (n === 0) return

    var peak = 1
    var series = []
    for (var a = 0; a < accts.length; a++) {
      var byDate = {}
      var list = accts[a].recentDays || []
      for (var j = 0; j < list.length; j++) byDate[String(list[j].date)] = Number(list[j].messageCount || 0)
      var values = dates.map(function(date) { return byDate[date] || 0 })
      for (var v = 0; v < values.length; v++) peak = Math.max(peak, values[v])
      series.push(values)
    }

    ctx.font = canvasFont(false)
    var peakLabel = usage.formatTokenCount(peak)
    var left = Math.max(Style.space(30), ctx.measureText(peakLabel).width + Style.space(10))
    var right = Style.space(14), top = Style.space(8), bottom = Style.space(22)
    var pw = Math.max(1, w - left - right), ph = Math.max(1, h - top - bottom)
    function X(idx) { return left + (n === 1 ? pw / 2 : pw * root.clamp(idx, 0, n - 1) / (n - 1)) }
    function Y(val) { return top + ph * (1 - val / peak) }

    ctx.textBaseline = "middle"
    ctx.lineWidth = 1
    ctx.strokeStyle = css(root.foreground, 0.16)
    ctx.beginPath(); ctx.moveTo(left, Y(0)); ctx.lineTo(left + pw, Y(0)); ctx.stroke()
    ctx.strokeStyle = css(root.foreground, 0.08)
    dashLine(ctx, left, Y(peak), left + pw, Y(peak), 2, 3)
    ctx.fillStyle = css(root.foreground, 0.4)
    ctx.textAlign = "right"
    ctx.fillText("0", left - Style.space(6), Y(0))
    ctx.fillText(peakLabel, left - Style.space(6), Y(peak))

    for (var s = 0; s < series.length; s++) {
      var color = accountColor(s)
      var vals = series[s]
      ctx.fillStyle = css(color, 0.12)
      ctx.beginPath()
      ctx.moveTo(X(0), Y(0))
      for (var p = 0; p < n; p++) ctx.lineTo(X(p), Y(vals[p]))
      ctx.lineTo(X(n - 1), Y(0))
      ctx.closePath()
      ctx.fill()

      ctx.strokeStyle = css(color)
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(X(0), Y(vals[0]))
      for (var q = 1; q < n; q++) ctx.lineTo(X(q), Y(vals[q]))
      ctx.stroke()

      ctx.fillStyle = css(color)
      ctx.strokeStyle = css(root.surface)
      ctx.lineWidth = 1.5
      ctx.beginPath()
      ctx.arc(X(n - 1), Y(vals[n - 1]), Style.space(3), 0, Math.PI * 2)
      ctx.fill()
      ctx.stroke()

      // The day each weekly window opened, at its hour within that day.
      var pace = accts[s].pace
      if (pace && pace.windowStartMs > 0) {
        var start = new Date(pace.windowStartMs)
        var key = start.getFullYear() + "-" + pad2(start.getMonth() + 1) + "-" + pad2(start.getDate())
        var at = dates.indexOf(key)
        if (at >= 0) {
          var x = X(at + (start.getHours() + start.getMinutes() / 60) / 24)
          ctx.strokeStyle = css(color, 0.55)
          ctx.lineWidth = 1
          dashLine(ctx, x, top, x, Y(0), 2, 3)
          ctx.font = canvasFont(false)
          ctx.fillStyle = css(color, 0.85)
          ctx.textAlign = x > left + pw - Style.space(40) ? "right" : "left"
          ctx.fillText("reset", x + (ctx.textAlign === "left" ? 3 : -3), top + fs / 2)
        }
      }
    }

    var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var today = root.todayDate()
    for (var t = 0; t < n; t++) {
      var isToday = dates[t] === today
      ctx.font = canvasFont(isToday)
      ctx.fillStyle = isToday ? css(root.foreground) : css(root.foreground, 0.4)
      ctx.textAlign = "center"
      ctx.fillText(isToday ? "Today" : names[new Date(dates[t] + "T00:00:00").getDay()], X(t), h - fs / 2 - 1)
    }
  }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.launchTarget) root.launchAccount(root.launchTarget)
        else root.launchAgent()
      }
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    // The accounts view is a dashboard meant to be read whole; only the screen
    // caps it. Other providers keep the stock height.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, root.isClaude ? undefined : Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily
            trailingControl: Component { ProviderSwitch {} }

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Accounts: decision first ----------
          Column {
            id: claudeView
            visible: root.isClaude
            width: parent.width
            spacing: Style.space(12)

            Column {
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "NOW"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                width: parent.width
                textFormat: Text.StyledText
                text: root.provider && root.provider.allExhausted
                  ? "<font color='" + root.urgent + "'>Everything above 90%</font>"
                  : "Use <font color='" + root.accent + "'>"
                    + root.escapeHtml(root.recommendedAccount ? root.recommendedAccount.name : "—") + "</font>"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                visible: text !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.reasonText()
                color: Qt.lighter(root.dim, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }
            }

            Grid {
              id: tileGrid
              width: parent.width
              columns: Math.min(2, Math.max(1, root.accounts.length))
              columnSpacing: Style.space(10)
              rowSpacing: Style.space(10)

              readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns

              Repeater {
                model: root.accounts

                AccountTile {
                  required property var modelData
                  width: tileGrid.cellWidth
                  account: modelData
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "ring: week left · bar: session used · dot and tick: where linear pace would put you"
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "PACE THIS WINDOW"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Canvas {
              id: paceChart
              width: parent.width
              height: Style.space(180)
              property var series: root.accounts
              onSeriesChanged: requestPaint()
              onWidthChanged: requestPaint()
              onVisibleChanged: if (visible) requestPaint()
              onPaint: root.paintPace(getContext("2d"), width, height, series)
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "below the diagonal leaves headroom · above runs dry before the reset · dashed is the projection · each account on its own window"
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(tokensHeader.implicitHeight, legendRow.implicitHeight)

              PanelSectionHeader {
                id: tokensHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "TOKENS BY DAY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                id: legendRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)

                Repeater {
                  model: root.accounts

                  Row {
                    required property var modelData
                    required property int index
                    spacing: Style.space(5)

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(14)
                      height: Math.max(2, Style.space(2))
                      color: root.accountColor(index)
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.name
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            Canvas {
              id: dayChart
              width: parent.width
              height: Style.space(116)
              property var series: root.accounts
              property string today: root.todayDate()
              onSeriesChanged: requestPaint()
              onTodayChanged: requestPaint()
              onWidthChanged: requestPaint()
              onVisibleChanged: if (visible) requestPaint()
              onPaint: root.paintDays(getContext("2d"), width, height, series)

              MouseArea {
                id: dayChartHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }

              PanelToolTip {
                visible: dayChartHover.containsMouse
                text: root.windowTokensTooltip()
                fontFamily: root.fontFamily
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.models.slice(0, 3)

                Chip {
                  required property var modelData
                  label: modelData.name
                  value: usage.formatTokenCount(modelData.total)
                }
              }

              Repeater {
                model: root.scopedChips()

                Chip {
                  required property var modelData
                  value: modelData
                  muted: true
                }
              }
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(footerButtons.implicitHeight, footerMeta.implicitHeight)

              Row {
                id: footerButtons
                anchors.left: parent.left
                anchors.right: footerMeta.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                readonly property var order: root.launchOrder()

                Repeater {
                  model: footerButtons.order

                  ActionButton {
                    required property var modelData
                    required property int index
                    width: (footerButtons.width - footerButtons.spacing * (footerButtons.order.length - 1)) / Math.max(1, footerButtons.order.length)
                    text: "Open " + modelData.name
                    solid: index === 0
                    onClicked: root.launchAccount(modelData)
                  }
                }
              }

              Column {
                id: footerMeta
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: root.ageText(root.limitsAgeMs())
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: "r refresh"
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance && !root.isClaude
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0 && !root.isClaude
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !root.isClaude && !!root.provider && !!root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0 && !root.isClaude
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }

  // Compact segmented switch for the hero's trailing edge: one cell per
  // provider, the current one filled.
  component ProviderSwitch: Rectangle {
    visible: root.providers.length > 1
    implicitWidth: switchRow.implicitWidth + 2
    implicitHeight: switchRow.implicitHeight + 2
    color: "transparent"
    border.width: 1
    border.color: root.alpha(root.foreground, 0.22)
    radius: Math.max(Style.cornerRadius, Style.space(4))

    Row {
      id: switchRow
      anchors.centerIn: parent

      Repeater {
        model: root.providers

        Rectangle {
          id: switchCell
          required property var modelData
          required property int index
          readonly property bool current: index === root.providerIndex

          implicitWidth: switchLabel.implicitWidth + Style.space(18)
          implicitHeight: switchLabel.implicitHeight + Style.space(9)
          radius: Math.max(Style.cornerRadius - 1, Style.space(3))
          color: current ? root.alpha(root.foreground, 0.16)
            : (switchMouse.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent")

          Text {
            id: switchLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.shortProviderName(switchCell.modelData.providerName)
            color: switchCell.current ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: switchCell.current
          }

          MouseArea {
            id: switchMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectProvider(switchCell.index)
          }
        }
      }
    }
  }

  // One account: badge, weekly ring, 5-hour session bar, and the numbers
  // that decide whether to spend it now.
  component AccountTile: Rectangle {
    id: tile
    property var account: null

    readonly property int slot: account ? root.accountIndex(account) : 0
    readonly property color tint: root.accountColor(slot)
    readonly property bool recommended: !!account && !!root.provider && account.id === root.provider.recommended
    readonly property int sessions: account ? Number(account.openSessions || 0) : 0
    readonly property var weekly: account ? account.weekly : null
    readonly property var pace: account ? account.pace : null
    readonly property string notice: root.accountNotice(account)

    radius: Math.max(Style.cornerRadius, Style.space(7))
    color: recommended ? root.alpha(tint, 0.07)
      : (sessions > 0 ? root.alpha(root.secondary, 0.06) : root.alpha(root.foreground, 0.03))
    border.width: 1
    border.color: recommended ? tint
      : (sessions > 0 ? root.alpha(root.secondary, 0.35) : root.alpha(root.foreground, 0.12))
    implicitHeight: tileColumn.implicitHeight + Style.space(24)

    Column {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(12)
      spacing: Style.space(8)

      Item {
        width: parent.width
        implicitHeight: Math.max(tileName.implicitHeight, tileBadge.implicitHeight)

        Text {
          id: tileName
          anchors.left: parent.left
          anchors.right: tileBadge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: tile.account ? tile.account.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Row {
          id: tileBadge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Rectangle {
            visible: tile.sessions > 0
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            color: root.secondary
          }

          Text {
            visible: tile.sessions > 0
            textFormat: Text.PlainText
            text: tile.recommended ? String(tile.sessions)
              : tile.sessions + (tile.sessions === 1 ? " SESSION" : " SESSIONS")
            color: root.secondary
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 0.8
          }

          Text {
            visible: tile.recommended
            leftPadding: tile.sessions > 0 ? Style.space(4) : 0
            textFormat: Text.PlainText
            text: "USE"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 0.8
          }
        }
      }

      Item {
        width: parent.width
        implicitHeight: ring.height

        Ring {
          id: ring
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width, Style.space(128))
          height: width
          free: tile.weekly ? 1 - tile.weekly.percent : -1
          expected: tile.pace ? 1 - tile.pace.elapsedFraction : -1
          tint: tile.tint
        }

        Column {
          anchors.centerIn: ring

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: tile.weekly ? root.pct(1 - tile.weekly.percent) : "—"
            color: tile.weekly && tile.weekly.percent >= 0.9 ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: tile.weekly ? "week left" : "no limits"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(3)

        FactRow {
          label: "5h session"
          value: !tile.account || !tile.account.session ? "—"
            : (root.sessionStarted(tile.account) ? root.pct(tile.account.session.percent) : "idle")
          valueColor: tile.account && tile.account.session && tile.account.session.percent >= 0.9 ? root.urgent : root.foreground
        }

        PaceBar {
          width: parent.width
          value: tile.account && tile.account.session ? tile.account.session.percent : 0
          mark: root.sessionStarted(tile.account) ? tile.account.session.elapsedFraction : -1
          alarming: tile.account && tile.account.session ? tile.account.session.percent >= 0.9 : false
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(3)

        FactRow {
          label: "reset"
          value: tile.weekly ? root.whenLabel(tile.weekly.resetsAt) : "—"
        }

        FactRow {
          label: "time left"
          value: tile.weekly ? root.formatDuration(root.msUntil(tile.weekly.resetsAt)) : "—"
        }

        FactRow {
          visible: tile.recommended && !!tile.pace
          label: "per day"
          value: tile.pace ? "~" + root.pct(tile.pace.dailyBudget) : ""
          valueColor: tile.tint
        }

        FactRow {
          visible: !tile.recommended && !!tile.pace
          label: "on pace"
          value: tile.pace ? "~" + root.pct(tile.pace.projectedAtReset) + " at reset" : ""
          valueColor: tile.pace && tile.pace.projectedAtReset >= 0.9 ? root.urgent : tile.tint
        }

        FactRow {
          label: "this window"
          value: tile.account ? usage.formatTokenCount(Number(tile.account.tokensInWindow || 0))
            + (tile.account.tokensInWindowPartial ? " partial" : "") : "—"
        }
      }

      Text {
        visible: tile.notice !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: tile.notice
        color: tile.account && tile.account.authStatus !== "ok" ? root.alpha(root.urgent, 0.9) : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // Weekly ring: the arc is what is left, clockwise from the top; the light
  // dot sits just outside the ring where linear pace would leave you.
  component Ring: Canvas {
    id: ring
    property real free: -1
    property real expected: -1
    property color tint: root.foreground

    onFreeChanged: requestPaint()
    onExpectedChanged: requestPaint()
    onTintChanged: requestPaint()
    onWidthChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var thickness = Style.space(9)
      var cx = width / 2, cy = height / 2
      var r = Math.min(width, height) / 2 - thickness / 2 - Style.space(6)
      var start = -Math.PI / 2
      ctx.lineWidth = thickness
      ctx.lineCap = "round"
      ctx.strokeStyle = root.css(root.track)
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.stroke()
      if (free > 0.001) {
        ctx.strokeStyle = root.css(tint)
        ctx.beginPath()
        ctx.arc(cx, cy, r, start, start + Math.PI * 2 * Math.min(0.9999, free), false)
        ctx.stroke()
      }
      if (expected >= 0) {
        var angle = start + Math.PI * 2 * root.clamp(expected, 0, 1)
        var outer = r + thickness / 2 + Style.space(3)
        ctx.lineWidth = 1.5
        ctx.fillStyle = root.css(root.paceMark)
        ctx.strokeStyle = root.css(root.surface, 1)
        ctx.beginPath()
        ctx.arc(cx + outer * Math.cos(angle), cy + outer * Math.sin(angle), Style.space(3.5), 0, Math.PI * 2)
        ctx.fill()
        ctx.stroke()
      }
    }
  }

  // Thin used-meter with a tick where linear pace would be.
  component PaceBar: Item {
    id: paceBar
    property real value: 0
    property real mark: -1
    property bool alarming: false
    readonly property real thickness: Math.max(Style.space(5), 4)

    implicitHeight: thickness + Style.space(6)

    Rectangle {
      id: paceTrack
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: paceBar.thickness
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: paceTrack.left
      anchors.verticalCenter: paceTrack.verticalCenter
      height: paceTrack.height
      radius: paceTrack.radius
      width: paceBar.value > 0 ? Math.max(height, paceTrack.width * root.clamp(paceBar.value, 0, 1)) : 0
      color: paceBar.alarming ? root.urgent : root.foreground
    }

    Rectangle {
      visible: paceBar.mark >= 0
      width: Math.max(2, Style.space(2))
      height: paceBar.height
      radius: width / 2
      x: paceTrack.width * root.clamp(paceBar.mark, 0, 1) - width / 2
      color: root.paceMark
    }
  }

  component FactRow: Item {
    id: fact
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent ? parent.width : 0
    implicitHeight: Math.max(factLabel.implicitHeight, factValue.implicitHeight)

    Text {
      id: factLabel
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: fact.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: factValue
      anchors.right: parent.right
      textFormat: Text.PlainText
      text: fact.value
      color: fact.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property string value: ""
    property bool muted: false

    implicitWidth: chipRow.implicitWidth + Style.space(18)
    implicitHeight: chipRow.implicitHeight + Style.space(10)
    radius: height / 2
    color: root.alpha(root.foreground, 0.07)

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        visible: chip.label !== ""
        textFormat: Text.PlainText
        text: chip.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        text: chip.value
        color: chip.muted ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  component ActionButton: Rectangle {
    id: action
    property string text: ""
    property bool solid: false
    signal clicked()

    implicitHeight: actionLabel.implicitHeight + Style.space(18)
    radius: Math.max(Style.cornerRadius, Style.space(5))
    color: solid ? (actionMouse.containsMouse ? Qt.lighter(root.accent, 1.12) : root.accent)
      : (actionMouse.containsMouse ? root.alpha(root.foreground, 0.08) : "transparent")
    border.width: solid ? 0 : 1
    border.color: root.alpha(root.foreground, 0.25)

    Text {
      id: actionLabel
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: action.text
      color: action.solid ? root.surface : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }
}

// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// `<time>` element formatter. The server renders a UTC fallback into
// `textContent` (so non-JS users see something) and stamps the ISO
// `datetime` + a `data-format` mode; this hook rewrites textContent to
// the user's local timezone on mount/update.
//
//   <time
//     phx-hook="LocalTime"
//     id="when-<%= row.id %>"
//     datetime="2026-05-30T18:59:00Z"
//     data-format="absolute"
//   >May 30, 18:59 UTC</time>
//
// `data-format`:
//   - "absolute" → "May 30, 14:59 (your time)" / "May 30, 2027, 14:59"
//   - "relative" → "3m ago" / "Jul 14"
const LocalTime = {
  mounted() { this.format() },
  updated() { this.format() },

  format() {
    const iso = this.el.getAttribute("datetime")
    if (!iso) return
    const dt = new Date(iso)
    if (isNaN(dt.getTime())) return

    const mode = this.el.dataset.format || "absolute"
    const now = new Date()
    const sameYear = dt.getFullYear() === now.getFullYear()

    if (mode === "relative") {
      this.el.textContent = formatRelative(dt, now, sameYear)
    } else {
      this.el.textContent = formatAbsolute(dt, sameYear)
    }

    // Tooltip carries the full absolute local time on hover for the
    // relative form, and the ISO source for the absolute form — so
    // operators can always recover the exact value.
    const tooltip = mode === "relative"
      ? formatAbsolute(dt, sameYear)
      : iso
    this.el.setAttribute("title", tooltip)
  }
}

function formatRelative(dt, now, sameYear) {
  const diffMs = now - dt
  const sec = Math.round(diffMs / 1000)
  if (sec < 5) return "just now"
  if (sec < 60) return `${sec}s ago`
  const min = Math.round(sec / 60)
  if (min < 60) return `${min}m ago`
  const hr = Math.round(min / 60)
  if (hr < 24) return `${hr}h ago`
  const day = Math.round(hr / 24)
  if (day < 7) return `${day}d ago`
  // > 1w → switch to absolute short form
  return formatAbsolute(dt, sameYear, /*short*/ true)
}

function formatAbsolute(dt, sameYear, short = false) {
  const opts = short
    ? { month: "short", day: "numeric" }
    : sameYear
      ? { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }
      : { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }
  return dt.toLocaleString(undefined, opts)
}

// Clipboard copy. We use a delegated document-level click listener
// rather than a Phoenix hook for two reasons:
//
//   1. CSP forbids inline `onclick` handlers — historically every
//      Copy button broke silently because the inline handler was
//      stripped by the CSP middleware in prod.
//   2. The CSP-safe alternative (`phx-hook`) only attaches to
//      elements inside a LiveView container. Marketing pages
//      (controller-rendered: pack detail, install snippets, …) have
//      no LiveSocket, so a hook there is dead too.
//
// The button just needs `data-copy="#some-id"` (id of the element
// whose textContent to grab) OR `data-copy-text="literal string"`.
// Optional `data-copy-label-copied="Copied!"` overrides the flash
// label; otherwise it flips to "Copied" for 1.5s.
function setupCopyToClipboardDelegation() {
  async function tryWriteToClipboard(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text)
        return true
      }
    } catch (_e) { /* fall through */ }

    // Fallback for non-secure contexts (dev over plain http, some
    // embedded webviews). Off-screen textarea + execCommand("copy").
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.top = "-1000px"
    document.body.appendChild(ta)
    ta.select()
    let ok = false
    try { ok = document.execCommand("copy") } catch (_e) {}
    document.body.removeChild(ta)
    return ok
  }

  function resolveText(btn) {
    if (btn.dataset.copyText != null) return btn.dataset.copyText
    const sel = btn.dataset.copy
    if (!sel) return null
    const target = document.querySelector(sel)
    if (!target) return null
    // Strip the first content line's indentation (HEEx template
    // whitespace) and the same prefix from later lines, so a multi-line
    // snippet copies without the template's leading indentation, then
    // drop trailing whitespace. This CANNOT tell template indent from an
    // intentional leading space, so leading-whitespace-significant
    // content (e.g. a ` curl …` command relying on
    // HISTCONTROL=ignorespace to skip shell history) must be copied via
    // `data-copy-text` (the literal-string path above), not a selector.
    const raw = target.innerText
    const lines = raw.replace(/\s+$/, "").split("\n")
    while (lines.length && lines[0].trim() === "") lines.shift()
    if (!lines.length) return ""
    // Strip the indentation of the first content line, then apply the
    // same strip to every subsequent line (so a multi-line snippet
    // keeps its relative indentation).
    const indent = lines[0].match(/^[ \t]*/)[0]
    return lines.map(l => l.startsWith(indent) ? l.slice(indent.length) : l).join("\n")
  }

  function flashCopied(btn) {
    const original = btn.innerText
    btn.innerText = btn.dataset.copyLabelCopied || "Copied"
    if (btn._copyTimer) clearTimeout(btn._copyTimer)
    btn._copyTimer = setTimeout(() => { btn.innerText = original }, 1500)
  }

  document.addEventListener("click", async (e) => {
    // Closest so clicks on a nested icon/span inside the button still fire.
    const btn = e.target.closest("[data-copy], [data-copy-text]")
    if (!btn) return
    e.preventDefault()
    const text = resolveText(btn)
    if (text == null || text === "") return
    if (await tryWriteToClipboard(text)) flashCopied(btn)
  })
}
setupCopyToClipboardDelegation()

// Phoenix hook kept for back-compat with the MFA recovery codes panel
// which uses `phx-hook="CopyToClipboard"` and the older
// `data-clipboard-*` attribute names. New code should prefer the
// delegated `data-copy` pattern above so it works on marketing pages
// too. Body is identical to the delegated path.
const CopyToClipboard = {
  mounted() {
    this.handler = async (e) => {
      e.preventDefault()
      const text = this.resolveText()
      if (text == null || text === "") return
      if (await this.copy(text)) this.flashCopied()
    }
    this.el.addEventListener("click", this.handler)
  },
  destroyed() {
    if (this.handler) this.el.removeEventListener("click", this.handler)
  },
  resolveText() {
    if (this.el.dataset.clipboardText != null) {
      return this.el.dataset.clipboardText
    }
    const sel = this.el.dataset.clipboardTarget
    if (!sel) return null
    const target = document.querySelector(sel)
    return target ? target.innerText.trim() : null
  },
  async copy(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text)
        return true
      }
    } catch (_e) {}
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.top = "-1000px"
    document.body.appendChild(ta)
    ta.select()
    let ok = false
    try { ok = document.execCommand("copy") } catch (_e) {}
    document.body.removeChild(ta)
    return ok
  },
  flashCopied() {
    const original = this.el.innerText
    const restore = this.el.dataset.clipboardRestore || original
    this.el.innerText = this.el.dataset.clipboardCopied || "Copied"
    if (this._timer) clearTimeout(this._timer)
    this._timer = setTimeout(() => { this.el.innerText = restore }, 1500)
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: { LocalTime, CopyToClipboard }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket


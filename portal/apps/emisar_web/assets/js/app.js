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

// CSP forbids inline `onclick` handlers, so any copy-to-clipboard
// button has to go through a hook. Reads its source from either
// `data-clipboard-text` (literal text) or `data-clipboard-target`
// (#id of an element whose textContent we copy). Briefly swaps the
// button's label to "Copied" so the operator gets visible feedback.
const CopyToClipboard = {
  mounted() {
    this.handler = (e) => {
      e.preventDefault()
      const text = this.resolveText()
      if (text == null) return
      this.copy(text)
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
    return target ? target.textContent.trim() : null
  },
  async copy(text) {
    let ok = false
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text)
        ok = true
      }
    } catch (_e) { /* fall through to textarea fallback */ }

    if (!ok) {
      // execCommand fallback for non-secure contexts (dev over plain http,
      // some embedded webviews). Mount off-screen so it never flashes.
      const ta = document.createElement("textarea")
      ta.value = text
      ta.setAttribute("readonly", "")
      ta.style.position = "fixed"
      ta.style.top = "-1000px"
      document.body.appendChild(ta)
      ta.select()
      try { ok = document.execCommand("copy") } catch (_e) { ok = false }
      document.body.removeChild(ta)
    }

    if (ok) this.flashCopied()
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


// JS bundle for the authenticated console (every LiveView render). The
// static marketing site loads the much leaner `marketing.js` instead —
// see that file and `root.html.heex` for how the bundle is chosen.
//
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {setupCopyToClipboardDelegation} from "./copy.js"

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

// CSP-safe Copy buttons (`data-copy` / `data-copy-text`). Shared with the
// marketing bundle; see copy.js for why it's a delegated listener.
setupCopyToClipboardDelegation()

// Phoenix hook kept for back-compat with the MFA recovery codes panel
// which uses `phx-hook="CopyToClipboard"` and the older
// `data-clipboard-*` attribute names. New code should prefer the
// delegated `data-copy` pattern (copy.js) so it works on marketing pages
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
topbar.config({barColors: {0: "#36e6a5"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

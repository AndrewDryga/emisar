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
  // Future-aware, mirroring the server-side TimeHelpers.relative_time/2: a future
  // instant (an expiry) reads "in 45m", a past one "45m ago". Without the future
  // branch a future time gave a negative diff → `sec < 5` → a wrong "just now"
  // (the "expires just now" bug on held approvals).
  const diffMs = now - dt
  const future = diffMs < 0
  const sec = Math.round(Math.abs(diffMs) / 1000)
  const rel = (n, u) => (future ? `in ${n}${u}` : `${n}${u} ago`)
  if (sec < 5) return "just now"
  if (sec < 60) return rel(sec, "s")
  const min = Math.round(sec / 60)
  if (min < 60) return rel(min, "m")
  const hr = Math.round(min / 60)
  if (hr < 24) return rel(hr, "h")
  const day = Math.round(hr / 24)
  if (day < 7) return rel(day, "d")
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

// Live expiry countdown for a held approval. Ticks "Expires in MM:SS" (or "Hh MMm"
// when far out), shifting tone amber→rose as it nears zero. At zero it shows
// "Expired" and pushes `data-lapsed-event` so the server re-renders the terminal
// state immediately instead of waiting for the Oban sweeper — the server re-checks
// expires_at on render, so a skewed client clock can only TRIGGER, never decide.
const ExpiryCountdown = {
  mounted() {
    this.text = this.el.querySelector("[data-countdown-text]") || this.el
    this.render()
    this.timer = setInterval(() => this.render(), 1000)
  },
  destroyed() { clearInterval(this.timer) },
  render() {
    const ms = new Date(this.el.dataset.expiresAt) - new Date()
    if (ms <= 0) {
      this.text.textContent = "Expired"
      this.tone("rose")
      clearInterval(this.timer)
      const ev = this.el.dataset.lapsedEvent
      if (ev) this.pushEvent(ev, {})
      return
    }
    this.text.textContent = "Expires in " + this.format(ms)
    const min = ms / 60000
    this.tone(min < 5 ? "rose" : min < 30 ? "amber" : "zinc")
  },
  format(ms) {
    const t = Math.floor(ms / 1000)
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60
    return h > 0
      ? `${h}h ${String(m).padStart(2, "0")}m`
      : `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
  },
  tone(name) {
    const cls = { rose: "text-rose-400", amber: "text-amber-400", zinc: "text-zinc-400" }
    this.el.classList.remove("text-rose-400", "text-amber-400", "text-zinc-400")
    this.el.classList.add(cls[name])
  }
}

// Persisted collapse state for `<.collapsible_section>` — a `<details>` that
// works on its own (native toggle, keyboard-accessible); this hook only adds
// memory. Restores the per-section choice from localStorage on mount AND after
// every LiveView patch (so a re-render of the body — e.g. a settings value
// changing — can't snap an expanded section shut), and saves on toggle. Keyed
// by `data-collapse-key`, so the choice sticks across navigations and reloads.
const CollapsibleSection = {
  mounted() {
    this.restore()
    this.el.addEventListener("toggle", () =>
      localStorage.setItem(this.storageKey(), this.el.open ? "1" : "0")
    )
  },
  updated() {
    this.restore()
  },
  storageKey() {
    return "collapse:" + (this.el.dataset.collapseKey || this.el.id)
  },
  restore() {
    const stored = localStorage.getItem(this.storageKey())
    if (stored !== null) this.el.open = stored === "1"
  }
}

// Resend cooldown for the magic-link "?sent=1" page — disables the resend button
// for data-seconds, ticking "Resend in M:SS", then re-enables it with data-label.
// The button ships ENABLED from the server so it still works without JS (the
// server throttle is the real limit); this hook only adds the soft client cooldown.
const ResendCooldown = {
  mounted() {
    this.label = this.el.dataset.label || "Resend code"
    this.until = Date.now() + (parseInt(this.el.dataset.seconds, 10) || 30) * 1000
    this.tick()
    this.timer = setInterval(() => this.tick(), 250)
  },
  destroyed() { clearInterval(this.timer) },
  tick() {
    const ms = this.until - Date.now()
    if (ms <= 0) {
      this.el.disabled = false
      this.el.textContent = this.label
      clearInterval(this.timer)
      return
    }
    const total = Math.ceil(ms / 1000)
    const m = Math.floor(total / 60), s = total % 60
    this.el.disabled = true
    this.el.textContent = `Resend in ${m}:${String(s).padStart(2, "0")}`
  }
}

// Magic-link code expiry on the "?sent=1" page — counts the emailed code down to
// data-expires-at ("Code expires in M:SS"). On lapse it disables the code submit
// (the element id in data-disable) and swaps to an "expired, resend" note, so a
// dead code can't be submitted and the resend button below is the next step.
const MagicCodeExpiry = {
  mounted() {
    this.expiresAt = new Date(this.el.dataset.expiresAt)
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  },
  destroyed() { clearInterval(this.timer) },
  tick() {
    const ms = this.expiresAt - new Date()
    if (ms <= 0) {
      this.el.textContent = "This code has expired — resend a fresh one below."
      this.el.classList.remove("text-brand-300/80")
      this.el.classList.add("text-amber-400")
      const target = this.el.dataset.disable && document.getElementById(this.el.dataset.disable)
      if (target) target.disabled = true
      clearInterval(this.timer)
      return
    }
    const t = Math.ceil(ms / 1000), m = Math.floor(t / 60), s = t % 60
    this.el.textContent = `Code expires in ${m}:${String(s).padStart(2, "0")}.`
  }
}

// iPhone-style one-box-per-char code entry — sign-in codes, TOTP, email step-up.
// The boxes are client-owned — the form submits the hidden [data-code] aggregate —
// so the container carries phx-update="ignore" and a LiveView re-render (flash, an
// expiry countdown) can't wipe what you typed. Handles: filter to the code alphabet
// (alphanumeric, or digits-only via data-numeric), auto-advance, backspace-to-
// previous, arrow nav, paste/autofill spread across boxes, and auto-submit once all
// boxes are full. No-JS falls back to the email link (sign-in) or a plain submit.
const CodeInput = {
  mounted() {
    this.boxes = Array.from(this.el.querySelectorAll("[data-box]"))
    this.hidden = this.el.querySelector("[data-code]")
    if (!this.boxes.length || !this.hidden) return

    const numeric = this.el.dataset.numeric === "true"
    const clean = numeric
      ? (s) => s.replace(/[^0-9]/g, "")
      : (s) => s.toUpperCase().replace(/[^0-9A-Z]/g, "")
    const sync = () => { this.hidden.value = this.boxes.map(b => b.value).join("") }
    const focusBox = (i) => { const b = this.boxes[i]; if (b) { b.focus(); b.select() } }

    const maybeSubmit = () => {
      if (this.boxes.every(b => b.value.length === 1)) {
        const form = this.el.closest("form")
        if (form) { form.requestSubmit ? form.requestSubmit() : form.submit() }
      }
    }

    const spread = (chars, start) => {
      for (let k = 0; start + k < this.boxes.length && k < chars.length; k++) {
        this.boxes[start + k].value = chars[k]
      }
      sync()
      focusBox(Math.min(start + chars.length, this.boxes.length - 1))
      maybeSubmit()
    }

    this.boxes.forEach((box, i) => {
      box.addEventListener("input", () => {
        const v = clean(box.value)
        if (v.length > 1) { spread(v, i); return }   // autofill dumped the whole code in one box
        box.value = v
        sync()
        if (v && i < this.boxes.length - 1) focusBox(i + 1)
        maybeSubmit()
      })
      box.addEventListener("keydown", (e) => {
        if (e.key === "Backspace" && box.value === "" && i > 0) {
          e.preventDefault(); this.boxes[i - 1].value = ""; sync(); focusBox(i - 1)
        } else if (e.key === "ArrowLeft" && i > 0) {
          e.preventDefault(); focusBox(i - 1)
        } else if (e.key === "ArrowRight" && i < this.boxes.length - 1) {
          e.preventDefault(); focusBox(i + 1)
        }
      })
      box.addEventListener("paste", (e) => {
        e.preventDefault()
        const text = (e.clipboardData || window.clipboardData).getData("text") || ""
        spread(clean(text), 0)
      })
      box.addEventListener("focus", () => box.select())
    })

    // Don't let a manual "Sign in" click submit a half-typed code (it would burn
    // an attempt) — bounce focus to the first empty box instead.
    const form = this.el.closest("form")
    if (form) {
      form.addEventListener("submit", (e) => {
        if (this.hidden.value.length !== this.boxes.length) {
          e.preventDefault()
          const empty = this.boxes.find((b) => b.value === "")
          if (empty) empty.focus()
        }
      })
    }

    sync()
    focusBox(0)
  }
}

// Auto-dismiss a transient flash after data-close-ms, with a subtle countdown bar
// (`[data-flash-bar]`, scaleX shrinks toward the left) that shows the time left.
// Hovering pauses it so a reader keeps the alert up; the alert also stays
// click-to-dismiss (this just fires that same click on lapse). Reduced-motion:
// the bar is hidden and doesn't animate, but the alert still auto-closes — motion
// is never load-bearing. Connection-state flashes opt out (no data-close-ms).
const FlashAutoClose = {
  mounted() {
    this.duration = parseInt(this.el.dataset.closeMs, 10)
    if (!this.duration) return
    this.bar = this.el.querySelector("[data-flash-bar]")
    this.reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (this.reduce && this.bar) this.bar.style.display = "none"
    this.frame = (now) => this.tick(now)
    this.el.addEventListener("mouseenter", () => { this.paused = true })
    this.el.addEventListener("mouseleave", () => { this.paused = false; this.last = performance.now() })
    this.start()
  },
  updated() { if (this.duration) this.start() },   // a replaced message restarts the countdown
  destroyed() { this.stop() },
  start() {
    this.stop()
    this.paused = false
    this.elapsed = 0
    this.last = performance.now()
    this.raf = requestAnimationFrame(this.frame)
  },
  stop() {
    if (this.raf) cancelAnimationFrame(this.raf)
    this.raf = null
  },
  tick(now) {
    if (!this.paused) {
      this.elapsed += now - this.last
      if (this.bar && !this.reduce) {
        this.bar.style.transform = `scaleX(${Math.max(0, 1 - this.elapsed / this.duration)})`
      }
      if (this.elapsed >= this.duration) { this.el.click(); return }
    }
    this.last = now
    this.raf = requestAnimationFrame(this.frame)
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: { LocalTime, CopyToClipboard, ExpiryCountdown, CollapsibleSection, ResendCooldown, MagicCodeExpiry, CodeInput, FlashAutoClose }
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

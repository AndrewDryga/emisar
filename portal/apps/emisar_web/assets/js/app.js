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

// Searchable filter combobox (LiveTable `%Filter{search: true}`). The server
// renders the full option list; this hook is pure client behavior — open/close,
// type-to-filter over data-search, and selection (write the hidden input, fire
// the form's change). The root is phx-update="ignore" with a VALUE-KEYED id:
// unrelated live re-renders leave an open panel + query alone, and an actual
// value change replaces the whole node with a fresh server render.
const Combobox = {
  mounted() {
    this.trigger = this.el.querySelector("[data-combobox-trigger]")
    this.panel = this.el.querySelector("[data-combobox-panel]")
    this.search = this.el.querySelector("[data-combobox-search]")
    this.hidden = this.el.querySelector("[data-combobox-value]")
    this.options = Array.from(this.el.querySelectorAll("[data-combobox-option]"))
    this.descriptionPane = this.el.querySelector("[data-combobox-description]")

    // The hovered option's description mirrors into the footer pane — a fixed
    // strip instead of per-option tooltips (which would clip in the scroll).
    this.options.forEach((o) => {
      o.addEventListener("mouseenter", () => this.describe(o.dataset.description))
      o.addEventListener("mouseleave", () => this.describe(null))
    })

    this.trigger.addEventListener("click", () => this.toggle())
    this.search.addEventListener("input", () => this.filter())
    this.search.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        const first = this.options.find((o) => !o.parentElement.hidden)
        if (first) this.select(first)
      }
      if (e.key === "Escape") this.close()
    })
    this.options.forEach((o) => o.addEventListener("click", () => this.select(o)))
    this.onDocClick = (e) => { if (!this.el.contains(e.target)) this.close() }
    document.addEventListener("click", this.onDocClick)
  },

  destroyed() { document.removeEventListener("click", this.onDocClick) },

  toggle() { this.panel.hidden ? this.open() : this.close() },

  open() {
    this.panel.hidden = false
    // The field and its dropdown fuse into one continuous element while open:
    // the trigger's bottom corners square off against the panel.
    this.trigger.classList.add("rounded-b-none")
    this.search.value = ""
    this.filter()
    this.search.focus()
  },

  close() {
    this.panel.hidden = true
    this.trigger.classList.remove("rounded-b-none")
    this.describe(null)
  },

  describe(text) {
    if (!this.descriptionPane) return
    this.descriptionPane.textContent = text || ""
    this.descriptionPane.hidden = !text
  },

  filter() {
    const q = this.search.value.trim().toLowerCase()
    this.options.forEach((o) => {
      const hit = q === "" || (o.dataset.search || "").includes(q)
      o.parentElement.hidden = !hit
    })
  },

  select(option) {
    this.hidden.value = option.dataset.value
    this.close()
    // Bubbling input event → the surrounding filter form's phx-change fires;
    // the URL patch then re-renders this node (new value ⇒ new id).
    this.hidden.dispatchEvent(new Event("input", { bubbles: true }))
  }
}

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
    } else if (mode === "forensic") {
      this.el.textContent = formatForensic(dt)
    } else {
      this.el.textContent = formatAbsolute(dt, sameYear)
    }

    // Tooltip carries the full absolute stamp on hover for the relative
    // form — UTC first (the forensic reference) plus the viewer's local
    // time with its zone name — and the ISO source for absolute/forensic,
    // so operators can always recover the exact value.
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone
    // True UTC from the ISO instant — formatForensic renders LOCAL wall-clock
    // fields, which made the tooltip show the same time twice.
    const utc = dt.toISOString().replace("T", " ").slice(0, 19) + " UTC"
    const tooltip = mode === "relative"
      ? `${utc} · ${formatAbsolute(dt, false)} (${zone})`
      : iso
    // Styled-tooltip elements render the stamp as an instant CSS bubble fed
    // by data-tooltip; the native title would double it after a 1s dwell.
    if (this.el.hasAttribute("data-styled-tooltip")) {
      this.el.setAttribute("data-tooltip", tooltip)
    } else {
      this.el.setAttribute("title", tooltip)
    }
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

// Second-precision local timestamp for forensic surfaces (the audit trail):
// "2026-07-02 04:44:12" — fixed-width digits so a column of them aligns,
// seconds because eight events in one minute must still order visibly.
function formatForensic(dt) {
  const p = (n, w = 2) => String(n).padStart(w, "0")
  return `${dt.getFullYear()}-${p(dt.getMonth() + 1)}-${p(dt.getDate())} ` +
    `${p(dt.getHours())}:${p(dt.getMinutes())}:${p(dt.getSeconds())}`
}

// CSP-safe Copy buttons (`data-copy` / `data-copy-text`). Shared with the
// marketing bundle; see copy.js for why it's a delegated listener.
setupCopyToClipboardDelegation()

// Live expiry countdown for a held approval. Ticks "Expires in MM:SS" (or "Hh MMm"
// when far out), shifting tone amber→rose as it nears zero. At zero it shows
// "Expired" and pushes `data-lapsed-event` so the server re-renders the terminal
// state immediately instead of waiting for the expiry job — the server re-checks
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

// Escape-to-dismiss for the shared <.tooltip> (WCAG 1.4.13 "Dismissable"). The
// bubble reveals purely in CSS on :hover / :focus-within; this hook adds only the
// Escape leg the CSS can't — it hides the bubble WITHOUT moving focus off the
// trigger (so the operator keeps their place), then re-arms on the next hover or
// focus so the tip can show again.
const Tooltip = {
  mounted() {
    this.bubble = this.el.querySelector("[data-tooltip-bubble]")
    if (!this.bubble) return
    this.onKey = (e) => { if (e.key === "Escape") this.bubble.classList.add("hidden") }
    this.rearm = () => this.bubble.classList.remove("hidden")
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("mouseenter", this.rearm)
    this.el.addEventListener("focusin", this.rearm)
  },
  destroyed() {
    if (!this.bubble) return
    this.el.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("mouseenter", this.rearm)
    this.el.removeEventListener("focusin", this.rearm)
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: { LocalTime, Combobox, ExpiryCountdown, CollapsibleSection, ResendCooldown, MagicCodeExpiry, CodeInput, FlashAutoClose, Tooltip }
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

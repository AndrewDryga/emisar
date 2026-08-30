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
import {initDropdowns} from "./dropdown.js"
import {FlashAutoClose} from "./flash.js"
import {initOsTabs} from "./os_tabs.js"
import {positionOverlay} from "./overlay.js"
import {Tooltip} from "./tooltip.js"

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

// Searchable filter combobox (LiveTable `%Filter{search: true}` and runbook
// action pickers). The server renders options inline or into a lazy shared pool;
// this hook owns open/close, type-to-filter over data-search, and selection
// (write the hidden input, fire the form's change). The root is phx-update="ignore"
// with a VALUE-KEYED id:
// unrelated live re-renders leave an open panel + query alone, and an actual
// value change replaces the whole node with a fresh server render.
const Combobox = {
  mounted() {
    this.trigger = this.el.querySelector("[data-combobox-trigger]")
    this.panel = this.el.querySelector("[data-combobox-panel]")
    this.search = this.el.querySelector("[data-combobox-search]")
    this.hidden = this.el.querySelector("[data-combobox-value]")
    this.list = this.el.querySelector("[data-combobox-options]")
    this.options = Array.from(this.el.querySelectorAll("[data-combobox-option]"))
    this.sections = Array.from(this.el.querySelectorAll("[data-combobox-section]"))
    this.descriptionPane = this.el.querySelector("[data-combobox-description]")

    this.options.forEach((o) => this.wireOption(o))

    this.trigger.addEventListener("click", () => this.toggle())
    this.search.addEventListener("input", () => this.filter())
    this.search.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        const first = this.options.find((o) => !o.disabled && !o.parentElement.hidden)
        if (first) this.select(first)
      }
      if (e.key === "Escape") this.close()
    })
    this.onDocClick = (e) => { if (!this.el.contains(e.target)) this.close() }
    document.addEventListener("click", this.onDocClick)
    this.onReposition = () => this.position()
  },

  destroyed() {
    document.removeEventListener("click", this.onDocClick)
    this.poolObserver?.disconnect()
    this.untrack()
  },

  // The hovered option's description mirrors into the footer pane — a fixed
  // strip instead of per-option tooltips (which would clip in the scroll).
  wireOption(o) {
    o.addEventListener("mouseenter", () => this.describe(o.dataset.description))
    o.addEventListener("mouseleave", () => this.describe(null))
    o.addEventListener("click", () => this.select(o))
  },

  // A picker pointing at a shared catalog pool ships an empty panel; the
  // options clone in from the pool's <template> the first time it opens, and
  // this instance's selected state applies here because the pool is shared.
  hydrate() {
    if (this.hydrated) return true
    const sourceId = this.el.dataset.comboboxSource
    if (!sourceId) return true
    const pool = document.getElementById(sourceId)
    if (!pool || !this.list) return false
    this.hydrated = true
    this.list.querySelector("[data-combobox-loading]")?.remove()
    this.list.appendChild(pool.content.cloneNode(true))
    const known = new Set(this.options)
    const all = Array.from(this.el.querySelectorAll("[data-combobox-option]"))
    all.filter((o) => !known.has(o)).forEach((o) => this.wireOption(o))
    this.options = all
    this.sections = Array.from(this.el.querySelectorAll("[data-combobox-section]"))
    const selected = this.options.find((o) => o.dataset.value === this.hidden.value)
    if (selected) {
      selected.setAttribute("aria-selected", "true")
      selected.classList.add("bg-white/[0.06]", "text-zinc-100")
    }
    return true
  },

  watchForPool() {
    if (this.hydrate() || this.poolObserver) return
    this.poolObserver = new MutationObserver(() => {
      if (!this.hydrate()) return
      this.poolObserver.disconnect()
      this.poolObserver = null
      this.filter()
    })
    this.poolObserver.observe(document.body, {childList: true, subtree: true})
  },

  showLoading() {
    if (this.list.querySelector("[data-combobox-loading]")) return
    const li = document.createElement("li")
    li.dataset.comboboxLoading = ""
    li.className = "px-3 py-2 text-sm text-zinc-500"
    li.textContent = "Loading actions…"
    this.list.appendChild(li)
  },

  toggle() { this.panel.hidden ? this.open() : this.close() },

  open() {
    this.watchForPool()
    // Pool-backed picker whose options haven't rendered yet (poolObserver is
    // still waiting): show a loading cue instead of a blank panel.
    if (this.poolObserver) this.showLoading()
    this.search.value = ""
    this.filter()
    this.panel.hidden = false
    // Focus first: the browser may scroll the field into view to reveal it, and
    // that moves the rects the panel is measured against.
    this.search.focus()
    this.position()
    window.addEventListener("resize", this.onReposition)
    window.addEventListener("scroll", this.onReposition, true)
  },

  close() {
    this.panel.hidden = true
    this.untrack()
    this.trigger.classList.remove("rounded-b-none", "rounded-t-none")
    this.describe(null)
  },

  untrack() {
    window.removeEventListener("resize", this.onReposition)
    window.removeEventListener("scroll", this.onReposition, true)
  },

  // Opens the panel on the side that fits — a picker in the last row of a long
  // editor has none below it — through the geometry the tooltip bubble and the
  // dropdown panel share. The field and its panel fuse into one continuous
  // element while open, so the squared seam follows the side it opened on.
  position() {
    const side = positionOverlay(this.el, this.trigger, this.panel, "below")
    this.trigger.classList.toggle("rounded-b-none", side === "below")
    this.trigger.classList.toggle("rounded-t-none", side === "above")
  },

  describe(text) {
    if (!this.descriptionPane) return
    this.descriptionPane.textContent = text || ""
    this.descriptionPane.hidden = !text
    // The pane grows the panel by a row; an upward-opening panel measures from
    // its bottom edge, so it has to be re-anchored or it slides over the field.
    if (!this.panel.hidden) this.position()
  },

  filter() {
    const q = this.search.value.trim().toLowerCase()
    this.options.forEach((o) => {
      const hit = q === "" || (o.dataset.search || "").includes(q)
      o.parentElement.hidden = !hit
    })
    this.sections.forEach((section) => {
      const options = Array.from(section.querySelectorAll("[data-combobox-option]"))
      section.hidden = !options.some((option) => !option.parentElement.hidden)
    })
    // Typing shrinks the list, which shortens the panel — an upward-opening one
    // is anchored by its bottom edge, so it has to be re-measured as it narrows.
    if (!this.panel.hidden) this.position()
  },

  select(option) {
    if (option.disabled) return
    this.hidden.value = option.dataset.value
    this.close()
    // Bubbling input event → the surrounding filter form's phx-change fires;
    // the URL patch then re-renders this node (new value ⇒ new id).
    this.hidden.dispatchEvent(new Event("input", { bubbles: true }))
  }
}

// Client-side filtering for bounded multi-select menus. Selection remains
// LiveView-owned; this hook only narrows the already-rendered catalog so large
// runner and scope lists stay usable without duplicating server state.
const FilterableList = {
  mounted() { this.bind() },
  updated() { this.bind() },

  destroyed() {
    if (this.search && this.onInput) this.search.removeEventListener("input", this.onInput)
  },

  bind() {
    if (this.search && this.onInput) this.search.removeEventListener("input", this.onInput)

    this.search = this.el.querySelector("[data-filterable-search]")
    this.sections = Array.from(this.el.querySelectorAll("[data-filterable-section]"))
    this.empty = this.el.querySelector("[data-filterable-empty]")
    this.onInput = () => this.filter()
    this.search.addEventListener("input", this.onInput)
    this.filter()
  },

  filter() {
    const query = this.search.value.trim().toLowerCase()
    let anyVisible = false

    this.sections.forEach((section) => {
      const sectionMatches = (section.dataset.filterSearch || "").includes(query)
      const items = Array.from(section.querySelectorAll("[data-filterable-item]"))

      items.forEach((item) => {
        const itemMatches = (item.dataset.filterSearch || "").includes(query)
        item.hidden = query !== "" && !sectionMatches && !itemMatches
      })

      const sectionVisible = items.some((item) => !item.hidden)
      section.hidden = !sectionVisible
      anyVisible = anyVisible || sectionVisible
    })

    if (this.empty) this.empty.hidden = anyVisible
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
    // Styled timestamps use the shared tooltip component so the bubble can
    // flip at viewport edges and dismiss on Escape. Keep its initial ISO text
    // useful before JS, then replace it with the viewer-local exact stamp.
    const tooltipId = this.el.dataset.tooltipId
    const tooltipBubble = tooltipId && document.getElementById(tooltipId)
    if (tooltipBubble) {
      tooltipBubble.textContent = tooltip
      this.el.removeAttribute("title")
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

// `short` drops the time of day, never the year: a bare "Dec 20" seen in
// January reads as this December. Mirrors TimeHelpers.absolute_date/2, which
// picks the form off the calendar year rather than an elapsed-days threshold.
function formatAbsolute(dt, sameYear, short = false) {
  const opts = short
    ? sameYear
      ? { month: "short", day: "numeric" }
      : { year: "numeric", month: "short", day: "numeric" }
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

// The install-instruction OS switch (macOS/Linux vs Windows PowerShell). The
// server renders the detected default; this only handles the click, and the
// marketing bundle calls the identical function.
initOsTabs()

// Keeps an open <.dropdown> panel on screen — above its trigger when there's no
// room below, inside the canvas when it would run off an edge. Delegated at the
// document, so a panel a LiveView patch adds later needs no re-wiring; the
// marketing bundle calls the identical function.
initDropdowns()

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
      // Disable the boxes too — a dead code can't verify, so leaving them typeable
      // just invites six keystrokes that auto-submit into a guaranteed rejection.
      const group = this.el.dataset.disableInputs && document.getElementById(this.el.dataset.disableInputs)
      if (group) { group.querySelectorAll("[data-box]").forEach(b => { b.disabled = true; b.blur() }) }
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

    // The server can't clear the boxes by re-rendering (phx-update="ignore"), so a
    // rejected attempt arrives as an event addressed to this group's id. Emptying
    // them is what keeps a correction from being an instant resubmit: with the code
    // left in place, fixing one character refills all six and auto-submits, burning
    // another of the five attempts. Pages that never push it are unaffected.
    this.handleEvent("code:reset", ({id}) => {
      if (id !== this.el.id) return
      this.boxes.forEach(b => { b.value = "" })
      sync()
      focusBox(0)
    })

    sync()
    focusBox(0)
  }
}

// Return focus to the element that opened a client-side dialog — a
// <.confirm_dialog> or the shell's mobile nav drawer — when it closes. Those
// surfaces show/hide entirely via JS commands (no round-trip), so without this
// the opener's focus falls to <body> on Escape / backdrop / Cancel / the close
// button — a keyboard or screen-reader operator loses their place (UI-016).
// phx:show-start fires before the dialog's focus_first moves focus inward, so
// document.activeElement is still the opener there; phx:hide-end fires once it
// has fully closed. Tab containment inside the open dialog is Phoenix's own
// <.focus_wrap> in the markup, not this hook.
const DialogFocus = {
  mounted() {
    this.opener = null
    this.onShow = () => {
      const active = document.activeElement
      if (active && active !== document.body) this.opener = active
    }
    this.onHide = () => {
      if (this.opener && this.opener.isConnected) this.opener.focus()
      this.opener = null
    }
    this.el.addEventListener("phx:show-start", this.onShow)
    this.el.addEventListener("phx:hide-end", this.onHide)
  },
  destroyed() {
    this.el.removeEventListener("phx:show-start", this.onShow)
    this.el.removeEventListener("phx:hide-end", this.onHide)
  }
}

// LiveView's `phx-disable-with` correctly prevents duplicate pushes, but a
// natively-disabled button loses keyboard focus until the server replies. Lock
// its measured width while the label changes, then keep the operator's place
// when that same control survives the patch (typically an inline error or a
// retryable action). Successful actions that remove the control destroy the
// hook and deliberately do not move focus elsewhere. A closing confirmation
// dialog opts out because DialogFocus returns to its opener instead.
const PendingButton = {
  mounted() {
    this.shouldRestore = false
    this.onClick = () => {
      const idleWidth = this.el.getBoundingClientRect().width
      const clone = this.el.cloneNode(true)
      clone.removeAttribute("id")
      clone.removeAttribute("phx-hook")
      clone.textContent = this.el.getAttribute("phx-disable-with") || this.el.textContent
      Object.assign(clone.style, {
        position: "absolute",
        visibility: "hidden",
        width: "max-content",
        minWidth: "0",
        maxWidth: "none",
        pointerEvents: "none"
      })
      this.el.insertAdjacentElement("afterend", clone)
      this.pendingWidth = Math.max(idleWidth, clone.getBoundingClientRect().width)
      clone.remove()
      this.el.style.width = `${this.pendingWidth}px`
      this.shouldRestore =
        this.el.dataset.restoreFocus !== "false" && document.activeElement === this.el
    }
    this.el.addEventListener("click", this.onClick)
    this.observer = new MutationObserver(() => this.restore())
    this.observer.observe(this.el, {attributes: true, attributeFilter: ["disabled"]})
  },
  updated() { this.restore() },
  reconnected() { this.restore() },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.observer.disconnect()
  },
  restore() {
    if (!this.el.isConnected || this.el.disabled) return
    if (this.shouldRestore && document.activeElement === document.body) {
      this.el.focus({preventScroll: true})
    }
    if (this.pendingWidth) this.el.style.width = ""
    this.pendingWidth = null
    this.shouldRestore = false
  }
}

// "Close this tab" on the device-grant approval page. That tab was opened by
// the terminal (`open` / `xdg-open`), not by a script, so window.close() is
// honored only where the tab has no history of its own — and refused SILENTLY
// everywhere else, Firefox always. Still alive a beat later means it was
// refused, so reveal the sibling note (data-note-id) telling the operator to
// close it themselves; re-reveal after a patch, which would restore the
// server's hidden class.
const CloseTab = {
  mounted() {
    this.el.addEventListener("click", () => {
      window.close()
      setTimeout(() => this.reveal(), 200)
    })
  },
  updated() { if (this.blocked) this.reveal() },
  reveal() {
    this.blocked = true
    document.getElementById(this.el.dataset.noteId)?.classList.remove("hidden")
  }
}

// Browser timings are untrusted hints that complement Phoenix's server-side
// LiveView spans. Keep a tiny in-memory queue because a transport fallback can
// happen before the LiveView hook mounts; only closed enums and measurements
// leave the tab — never a URL, socket error, rendered content, or account id.
const portalPerformanceQueue = []
let portalTransport = "websocket"
let portalNavigation = null
let portalNavigationGeneration = 0
const portalSocketStartedAt = performance.now()

const queuePortalPerformance = (report) => {
  if (portalPerformanceQueue.length === 10) portalPerformanceQueue.shift()
  portalPerformanceQueue.push(report)
  window.dispatchEvent(new CustomEvent("emisar:portal-performance"))
}

const fallbackReason = (reason) => {
  if (reason === "memorized") return "memorized"
  if (reason == null) return "timeout"
  if (reason?.type === "close") return "close"
  return "error"
}

const portalSocketLogger = (kind, message, data) => {
  if (kind !== "transport") return

  if (message.startsWith("falling back to LongPoll")) {
    portalTransport = "long_poll"
    queuePortalPerformance({
      kind: "transport_fallback",
      reason: fallbackReason(data),
      elapsed_ms: Math.round(performance.now() - portalSocketStartedAt)
    })
  } else if (message === "connected to primary after") {
    portalTransport = "websocket"
  }
}

const PortalPerformance = {
  mounted() {
    this.flushReports = () => {
      while (portalPerformanceQueue.length > 0) {
        this.pushEvent("portal_performance", portalPerformanceQueue.shift())
      }
    }
    window.addEventListener("emisar:portal-performance", this.flushReports)
    this.flushReports()
  },
  updated() { this.flushReports() },
  destroyed() {
    window.removeEventListener("emisar:portal-performance", this.flushReports)
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // Tab-resume reconnects often finish inside LiveView's 500ms default. The
  // neutral recovery notice should still acknowledge the interruption.
  disconnectedTimeout: 100,
  logger: portalSocketLogger,
  params: {_csrf_token: csrfToken},
  hooks: { LocalTime, Combobox, FilterableList, ExpiryCountdown, ResendCooldown, MagicCodeExpiry, CodeInput, FlashAutoClose, Tooltip, DialogFocus, PendingButton, CloseTab, PortalPerformance }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#36e6a5"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => {
  portalNavigationGeneration += 1
  portalNavigation = document.visibilityState === "visible"
    ? {startedAt: performance.now(), generation: portalNavigationGeneration}
    : null
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  const navigation = portalNavigation
  portalNavigation = null
  if (navigation == null || document.visibilityState !== "visible") return

  const durationMs = Math.round(performance.now() - navigation.startedAt)
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (document.visibilityState !== "visible" ||
        navigation.generation !== portalNavigationGeneration) return

    queuePortalPerformance({
      kind: "navigation",
      duration_ms: durationMs,
      dom_bytes: new Blob([document.documentElement.outerHTML]).size,
      transport: portalTransport
    })
  }))
})
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") return
  portalNavigation = null
  portalNavigationGeneration += 1
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

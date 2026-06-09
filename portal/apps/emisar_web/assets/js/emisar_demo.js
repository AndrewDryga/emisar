// Interactive "watch emisar work" terminal on the marketing home page.
//
// Marketing pages are controller-rendered (no LiveSocket), so this runs as a
// plain DOM module on load — same reasoning as the clipboard delegation in
// app.js. CSP-safe: it ships inside the bundled app.js (script-src 'self'),
// never as an inline script, and builds the spinner from DOM nodes (no
// innerHTML).
//
// Progressive enhancement: the server renders the whole incident as static
// lines in two panes, so no-JS visitors and crawlers get the full story and
// the tabs degrade to a readable stacked transcript. Here we hide the lines
// and replay them in `data-seq` order — typing shell input, streaming
// install/runner output on the host tab, and rendering a faithful Claude
// Code session (thinking spinners, ⏺/⎿ tool calls, the approval beat) on the
// LLM tab. Honors prefers-reduced-motion (static render; tabs still work).

const CHAR_MS = 14

// A tab hop needs real time: first hold on the current pane so the viewer
// finishes reading it, then switch and let the new pane settle before the
// next line lands. A single 650ms beat read too fast to follow.
const TAB_HOLD_MS = 1300
const TAB_SETTLE_MS = 750

// Lines whose body is typed out character-by-character (the rest stream in).
const TYPED = new Set(["srv-prompt", "cc-user"])
// JS-only animated spinners (server-rendered hidden).
const SPINNER = new Set(["cc-spin", "cc-spin-wait"])

// Dwell after each line lands (ms) — the pacing of the narrative. Install
// lines stream fast like a real installer; the approval beat dwells.
const PAUSE = {
  "srv-comment": 350,
  "srv-prompt": 450,
  "srv-install": 170,
  "srv-banner": 380,
  "srv-log": 280,
  "srv-ok": 650,
  "cc-meta": 400,
  "cc-user": 550,
  "cc-text": 560,
  "cc-tool": 380,
  "cc-result": 320,
  "cc-result-cont": 220,
  "cc-diff-note": 90,
  "cc-diff-ctx": 90,
  "cc-diff-add": 280,
  "cc-pending": 750,
  "cc-approved": 850
}

// Claude's twinkling-star spinner glyph cycle.
const SPIN_GLYPHS = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
const SPIN_TICK_MS = 110

export function initEmisarDemo() {
  const root = document.querySelector("[data-emisar-demo]")
  if (!root) return

  const tabs = Array.from(root.querySelectorAll("[data-demo-tab]"))
  const panes = Array.from(root.querySelectorAll("[data-demo-pane]"))
  const screen = root.querySelector("[data-demo-screen]")
  const replay = root.querySelector("[data-demo-replay]")
  const lines = Array.from(root.querySelectorAll("[data-demo-line]")).sort(
    (a, b) => seqOf(a) - seqOf(b)
  )
  if (!tabs.length || !panes.length || !lines.length) return

  // Snapshot each line's final text so we can clear it and replay.
  lines.forEach((l) => { l.dataset.text = l.textContent })

  let timers = []
  let playing = false

  const reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches

  function seqOf(el) { return parseInt(el.dataset.seq || "0", 10) }
  function isSpinner(el) { return SPINNER.has(el.dataset.kind) }
  function clearTimers() { timers.forEach(clearTimeout); timers = [] }
  function later(ms, fn) { const t = setTimeout(fn, ms); timers.push(t); return t }
  function firstTab() { return lines[0].dataset.tab }

  function showTab(name) {
    tabs.forEach((t) => t.setAttribute("aria-selected", String(t.dataset.demoTab === name)))
    panes.forEach((p) => { p.hidden = p.dataset.demoPane !== name })
  }

  function stripCursor() {
    const c = root.querySelector(".demo-cursor")
    if (c) c.remove()
  }

  function scrollToEnd() {
    if (screen) screen.scrollTop = screen.scrollHeight
  }

  // Static: every non-spinner line visible with its final text. Spinners
  // stay hidden (they're motion). Tabs still switch panes.
  function revealAll() {
    clearTimers()
    playing = false
    stripCursor()
    lines.forEach((l) => {
      if (isSpinner(l)) { l.hidden = true; return }
      l.textContent = l.dataset.text
      l.hidden = false
    })
  }

  function play() {
    clearTimers()
    stripCursor()
    playing = true
    lines.forEach((l) => { l.hidden = true; l.textContent = "" })
    showTab(firstTab())

    let i = 0
    let shownTab = firstTab()

    const render = (line, kind, pause) => {
      if (SPINNER.has(kind)) {
        animateSpinner(line, kind, next)
      } else if (TYPED.has(kind)) {
        line.hidden = false
        typeInto(line, line.dataset.text, () => later(pause, next))
      } else {
        line.hidden = false
        line.textContent = line.dataset.text
        scrollToEnd()
        later(pause, next)
      }
    }

    const next = () => {
      if (!playing) return
      if (i >= lines.length) { playing = false; return }
      const line = lines[i++]
      const kind = line.dataset.kind || ""
      const pause = PAUSE[kind] != null ? PAUSE[kind] : 320

      // Switching panes? Hold on the current pane so the viewer can finish
      // reading it, then switch and let the new pane settle before the line
      // lands — otherwise the story yanks away mid-sentence.
      if (line.dataset.tab !== shownTab) {
        later(TAB_HOLD_MS, () => {
          if (!playing) return
          shownTab = line.dataset.tab
          showTab(shownTab)
          scrollToEnd()
          later(TAB_SETTLE_MS, () => render(line, kind, pause))
        })
      } else {
        render(line, kind, pause)
      }
    }
    next()
  }

  function typeInto(el, text, done) {
    const cursor = document.createElement("span")
    cursor.className = "demo-cursor"
    cursor.setAttribute("aria-hidden", "true")
    let n = 0
    const tick = () => {
      if (!playing) return
      el.textContent = text.slice(0, n)
      el.appendChild(cursor)
      scrollToEnd()
      if (n++ < text.length) {
        later(CHAR_MS, tick)
      } else {
        cursor.remove()
        done()
      }
    }
    tick()
  }

  // Claude's thinking spinner: glyph cycles, seconds tick up, a token
  // counter climbs, then it vanishes and the next line lands — exactly the
  // "✻ Working… (3s · ↑ 1.4k tokens · esc to interrupt)" beat.
  function animateSpinner(line, kind, done) {
    line.hidden = false
    const word = line.dataset.text
    const totalMs = kind === "cc-spin-wait" ? 2600 : 1300
    let elapsed = 0
    let gi = 0
    let tokens = 1.1 + Math.random() * 0.5

    const draw = () => {
      const secs = Math.max(1, Math.round(elapsed / 1000))
      line.textContent = ""
      const glyph = document.createElement("span")
      glyph.className = "demo-spin-glyph"
      glyph.textContent = SPIN_GLYPHS[gi % SPIN_GLYPHS.length]
      line.appendChild(glyph)
      line.appendChild(
        document.createTextNode(
          " " + word + "… (" + secs + "s · ↑ " + tokens.toFixed(1) + "k tokens · esc to interrupt)"
        )
      )
    }

    const tick = () => {
      if (!playing) return
      draw()
      scrollToEnd()
      if (elapsed >= totalMs) {
        line.hidden = true
        done()
        return
      }
      elapsed += SPIN_TICK_MS
      gi++
      tokens += 0.1 + Math.random() * 0.2
      later(SPIN_TICK_MS, tick)
    }
    tick()
  }

  // A tab click hands control to the visitor: stop the replay, reveal the
  // whole transcript, switch.
  tabs.forEach((t) =>
    t.addEventListener("click", () => {
      revealAll()
      showTab(t.dataset.demoTab)
      if (screen) screen.scrollTop = 0
    })
  )

  if (replay) replay.addEventListener("click", () => play())

  if (reduceMotion) {
    revealAll()
    showTab(firstTab())
    return
  }

  // Static until scrolled into view, then play once.
  showTab(firstTab())
  if (!("IntersectionObserver" in window)) {
    play()
    return
  }
  let started = false
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting && !started) {
          started = true
          io.disconnect()
          play()
        }
      })
    },
    { threshold: 0.3 }
  )
  io.observe(root)
}

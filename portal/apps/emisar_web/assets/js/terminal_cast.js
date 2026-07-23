// Lightweight, self-contained terminal casts for the docs pages (a "watch it
// run" without a 200 KiB player or a video file). Same reasoning as
// emisar_demo.js: marketing/docs pages are controller-rendered with no
// LiveSocket, so this is a plain DOM module. CSP-safe — it ships in the
// bundled marketing.js (script-src 'self'), never inline, and never uses
// innerHTML.
//
// Progressive enhancement: the server renders every line as static text (a
// prompt span + a text span), so no-JS visitors and crawlers get the whole
// transcript. Here we hide the text, then replay it in DOM order — typing the
// commands character-by-character with a cursor and streaming the output —
// once the cast scrolls into view. Multiple casts per page are independent.
// Honors prefers-reduced-motion (static render).

const CHAR_MS = 16

// Dwell after each line lands (ms). Commands and the LLM prompt feel typed;
// output streams fast; success/notes hold a beat so the eye catches them.
const PAUSE = {
  cmd: 340,
  llm: 460,
  out: 190,
  sys: 150,
  install: 150,
  ok: 560,
  warn: 720,
  note: 300,
  blank: 130
}

// Lines whose text is typed out character-by-character (the rest stream in).
const TYPED = new Set(["cmd", "llm"])

export function initTerminalCasts() {
  document.querySelectorAll("[data-terminal-cast]").forEach(setupCast)
}

function setupCast(root) {
  const screen = root.querySelector("[data-cast-screen]")
  const replay = root.querySelector("[data-cast-replay]")
  const lines = Array.from(root.querySelectorAll("[data-cast-line]"))
  if (!lines.length) return

  // Snapshot each line's final text (from its text span) so we can clear and
  // replay it; the prompt glyph stays put.
  const cells = lines.map((line) => {
    const text = line.querySelector("[data-cast-text]")
    return { line, text, final: text ? text.textContent : "" }
  })

  let timers = []
  let playing = false

  const reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches

  function clearTimers() {
    timers.forEach(clearTimeout)
    timers = []
  }
  function later(ms, fn) {
    const t = setTimeout(fn, ms)
    timers.push(t)
    return t
  }
  function stripCursor() {
    const c = root.querySelector(".cast-cursor")
    if (c) c.remove()
  }
  function scrollToEnd() {
    if (screen) screen.scrollTop = screen.scrollHeight
  }

  // Static: every line visible with its final text.
  function revealAll() {
    clearTimers()
    playing = false
    stripCursor()
    cells.forEach(({ line, text, final }) => {
      if (text) text.textContent = final
      line.hidden = false
    })
  }

  function play() {
    clearTimers()
    stripCursor()
    playing = true
    if (screen) screen.scrollTop = 0
    cells.forEach(({ line, text }) => {
      line.hidden = true
      if (text) text.textContent = ""
    })

    let i = 0
    const next = () => {
      if (!playing) return
      if (i >= cells.length) {
        playing = false
        return
      }
      const { line, text, final } = cells[i++]
      const kind = line.dataset.kind || "out"
      const pause = PAUSE[kind] != null ? PAUSE[kind] : 260
      line.hidden = false
      if (text && TYPED.has(kind)) {
        typeInto(text, final, () => later(pause, next))
      } else {
        if (text) text.textContent = final
        scrollToEnd()
        later(pause, next)
      }
    }
    next()
  }

  function typeInto(el, text, done) {
    const cursor = document.createElement("span")
    cursor.className = "cast-cursor"
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

  if (replay) replay.addEventListener("click", play)

  if (reduceMotion) {
    revealAll()
    return
  }

  // Hide, then play once — when scrolled into view, or on a short fallback so
  // it can NEVER sit frozen-empty if the observer doesn't fire (already in view
  // on load, a flaky observer, etc.). play() clears the fallback timer.
  cells.forEach(({ line }) => (line.hidden = true))
  let started = false
  const start = () => {
    if (started) return
    started = true
    play()
  }
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          io.disconnect()
          start()
        }
      },
      { threshold: 0.2 }
    )
    io.observe(root)
    later(2000, start)
  } else {
    start()
  }
}

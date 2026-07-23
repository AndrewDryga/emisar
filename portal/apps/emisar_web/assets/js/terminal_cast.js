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
// once the cast scrolls into view. Honors prefers-reduced-motion (static).
//
// A cast is either single (one [data-cast-screen] of lines) or tabbed (one or
// more [data-cast-pane] panes inside the screen, switched by [data-cast-tab]
// buttons in the header, like the home-page demo). Each pane is an independent
// transcript; switching tabs plays that pane.

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

// One pane's typed transcript. `screen` is the scroll box; `container` holds the
// lines — the same element in single mode, the pane in tabbed mode.
function makeCast(screen, container) {
  const lines = Array.from(container.querySelectorAll("[data-cast-line]"))
  const cells = lines.map((line) => {
    const text = line.querySelector("[data-cast-text]")
    return { line, text, final: text ? text.textContent : "" }
  })

  let timers = []
  let playing = false

  const clearTimers = () => {
    timers.forEach(clearTimeout)
    timers = []
  }
  const later = (ms, fn) => {
    const t = setTimeout(fn, ms)
    timers.push(t)
    return t
  }
  const stripCursor = () => {
    const c = container.querySelector(".cast-cursor")
    if (c) c.remove()
  }
  const scrollToEnd = () => {
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

  function hideAll() {
    clearTimers()
    playing = false
    stripCursor()
    cells.forEach(({ line, text }) => {
      line.hidden = true
      if (text) text.textContent = ""
    })
  }

  function typeInto(el, final, done) {
    const cursor = document.createElement("span")
    cursor.className = "cast-cursor"
    cursor.setAttribute("aria-hidden", "true")
    let n = 0
    const tick = () => {
      if (!playing) return
      el.textContent = final.slice(0, n)
      el.appendChild(cursor)
      scrollToEnd()
      if (n++ < final.length) {
        later(CHAR_MS, tick)
      } else {
        cursor.remove()
        done()
      }
    }
    tick()
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

  return {play, revealAll, hideAll, stop: clearTimers}
}

function setupCast(root) {
  const screen = root.querySelector("[data-cast-screen]")
  if (!screen) return
  const replay = root.querySelector("[data-cast-replay]")
  const panes = Array.from(root.querySelectorAll("[data-cast-pane]"))
  const tabs = Array.from(root.querySelectorAll("[data-cast-tab]"))
  const containers = panes.length ? panes : [screen]
  const casts = containers.map((c) => makeCast(screen, c))

  const reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches

  let active = 0

  function showPane(i) {
    if (panes.length) panes.forEach((p, j) => (p.hidden = j !== i))
    tabs.forEach((t, j) => t.setAttribute("aria-selected", j === i ? "true" : "false"))
  }

  // Replay + tab clicks target the active pane; static mode reveals, animated plays.
  const run = (i) => (reduceMotion ? casts[i].revealAll() : casts[i].play())
  tabs.forEach((t, i) =>
    t.addEventListener("click", () => {
      casts.forEach((c) => c.stop())
      active = i
      showPane(i)
      run(i)
    })
  )
  if (replay) replay.addEventListener("click", () => run(active))

  if (reduceMotion) {
    casts.forEach((c) => c.revealAll())
    showPane(active)
    return
  }

  // Freeze the screen at the tallest pane's height so playback AND tab switches
  // fill a fixed box instead of growing the page. Measure each pane while its
  // lines are still server-rendered-visible (font-mono is a system stack, so it
  // measures true); overflow-y-auto still scrolls a cast past its max height.
  if (panes.length) {
    let max = 0
    panes.forEach((p) => {
      panes.forEach((q) => (q.hidden = q !== p))
      max = Math.max(max, screen.getBoundingClientRect().height)
    })
    showPane(active)
    if (max) screen.style.height = `${max}px`
  } else {
    const h = screen.getBoundingClientRect().height
    if (h) screen.style.height = `${h}px`
  }

  // Hide every line, then play the active pane once — when scrolled into view, or
  // on a short fallback so it can NEVER sit frozen-empty (already in view, a flaky
  // observer, etc.). play() resets the pane before typing.
  casts.forEach((c) => c.hideAll())
  showPane(active)
  let started = false
  const start = () => {
    if (started) return
    started = true
    casts[active].play()
  }
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          io.disconnect()
          start()
        }
      },
      {threshold: 0.2}
    )
    io.observe(root)
    setTimeout(start, 2000)
  } else {
    start()
  }
}

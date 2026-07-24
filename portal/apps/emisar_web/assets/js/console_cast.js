// Auto-advancing console screencasts (the /security approval-loop section) —
// a "watch the console work" without a video file or a player library, same
// reasoning as terminal_cast.js. Marketing pages are controller-rendered with
// no LiveSocket, so this is a plain DOM module. CSP-safe: bundled in
// marketing.js (script-src 'self'), never inline, no innerHTML; the only
// inline styles are CSSOM positions/transitions, which style-src does not
// govern.
//
// Progressive enhancement: the server renders the full storyboard — every
// frame with its step label and caption — so no-JS visitors and crawlers get
// the whole story stacked. Here we collapse the storyboard into one stacked
// stage and PLAY the take once it scrolls into view: an overlay cursor
// travels to the active frame's declared click point, a ripple fires, and the
// next frame crossfades in — the transitions read as the real interaction
// that produced the captures (which they were: the frames come from a live
// driven session, tools/internal/browser/docs.go captureLoopTake). A tab
// click takes manual control and stops the autoplay; Replay runs it again.
// Honors prefers-reduced-motion: no autoplay, no cursor, instant swaps, tabs
// still work, annotations still shown.

// The read beat on a frame before its transition starts, and the cursor's
// travel + click beats. Slower than a slideshow, faster than a demo video.
const DWELL_MS = 2600
const TRAVEL_MS = 550
const CLICK_MS = 420
const NOTE_DELAY_MS = 500

export function initConsoleCasts() {
  document.querySelectorAll("[data-console-cast]").forEach(setupCast)
}

function parsePoint(value) {
  if (!value) return null
  const [x, y] = value.split(",").map((part) => parseFloat(part))
  return Number.isFinite(x) && Number.isFinite(y) ? {x, y} : null
}

function setupCast(root) {
  const stage = root.querySelector("[data-cast-stage]")
  const frames = Array.from(root.querySelectorAll("[data-cast-frame]"))
  const steps = Array.from(root.querySelectorAll("[data-cast-step]"))
  const stepsWrap = root.querySelector("[data-cast-steps]")
  const replay = root.querySelector("[data-cast-replay]")
  const cursor = root.querySelector("[data-cast-cursor]")
  const ripple = root.querySelector("[data-cast-ripple]")
  if (!stage || frames.length < 2) return

  const reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches

  // Storyboard → stacked stage: every frame shares one grid cell; the active
  // one is opaque. The per-frame "Step N" headings duplicate the tabs, so
  // they only exist for the storyboard reading.
  stage.classList.remove("space-y-10")
  stage.classList.add("grid")
  frames.forEach((frame) => {
    frame.classList.add(
      "col-start-1",
      "row-start-1",
      "transition-opacity",
      "duration-500",
      "motion-reduce:transition-none"
    )
    frame.querySelectorAll("[data-cast-frame-label]").forEach((label) => (label.hidden = true))
    // The stacked frames are the section's core and swap on a timer or a tab
    // click, so decode them all now — server-side lazy is only for the no-JS
    // storyboard, where each frame loads as the reader reaches it.
    frame.querySelectorAll("img").forEach((img) => {
      img.loading = "eager"
    })
  })
  if (stepsWrap) stepsWrap.hidden = false
  if (replay) replay.hidden = false

  let active = 0
  let timers = []

  const later = (ms, fn) => timers.push(setTimeout(fn, ms))
  const stop = () => {
    timers.forEach(clearTimeout)
    timers = []
  }

  // The active frame's image box, in stage coordinates — every frame's image
  // shares the same geometry once stacked, so measure the first.
  const imageBox = () => {
    const img = frames[0].querySelector("img")
    const stageBox = stage.getBoundingClientRect()
    const box = img.getBoundingClientRect()
    return {left: box.left - stageBox.left, top: box.top - stageBox.top, width: box.width, height: box.height}
  }

  const placeAt = (el, point) => {
    const box = imageBox()
    el.style.left = box.left + (point.x / 100) * box.width + "px"
    el.style.top = box.top + (point.y / 100) * box.height + "px"
  }

  const showNote = (frame) => {
    const note = frame.querySelector("[data-cast-note]")
    if (!note) return
    const at = parsePoint(note.dataset.noteAt)
    if (!at) return
    // On a phone the frame renders ~340px wide — a pill over it covers half
    // the screen it annotates. The captions below carry the same information.
    if (imageBox().width < 480) return
    // Anchor the pill just above its target point, inside the image.
    note.style.left = at.x + "%"
    note.style.top = at.y + "%"
    note.style.transform = "translate(-50%, -140%)"
    note.hidden = false
    later(NOTE_DELAY_MS, () => note.classList.remove("opacity-0"))
  }

  const hideNotes = () => {
    frames.forEach((frame) =>
      frame.querySelectorAll("[data-cast-note]").forEach((note) => {
        note.classList.add("opacity-0")
        note.hidden = true
      })
    )
  }

  const show = (index) => {
    active = index
    hideNotes()
    frames.forEach((frame, i) => {
      frame.classList.toggle("opacity-0", i !== index)
      frame.classList.toggle("pointer-events-none", i !== index)
      frame.setAttribute("aria-hidden", String(i !== index))
    })
    steps.forEach((step, i) => step.setAttribute("aria-selected", String(i === index)))
    showNote(frames[index])
  }

  const hideCursor = () => {
    if (cursor) {
      cursor.hidden = true
      cursor.classList.add("opacity-0")
    }
    if (ripple) ripple.hidden = true
  }

  const clickRipple = (point) => {
    if (!ripple) return
    placeAt(ripple, point)
    ripple.hidden = false
    ripple.classList.add("animate-ping")
    later(CLICK_MS, () => {
      ripple.classList.remove("animate-ping")
      ripple.hidden = true
    })
  }

  // One transition: travel the cursor to the frame's click point, click, then
  // crossfade to the next frame and queue the one after.
  const advance = () => {
    if (active >= frames.length - 1) return
    const click = parsePoint(frames[active].dataset.click)
    if (!click || !cursor) {
      show(active + 1)
      queue()
      return
    }
    cursor.hidden = false
    cursor.style.transition = `left ${TRAVEL_MS}ms cubic-bezier(0.4, 0, 0.2, 1), top ${TRAVEL_MS}ms cubic-bezier(0.4, 0, 0.2, 1), opacity 200ms`
    cursor.classList.remove("opacity-0")
    placeAt(cursor, click)
    later(TRAVEL_MS + 60, () => {
      clickRipple(click)
      later(CLICK_MS - 60, () => {
        show(active + 1)
        queue()
      })
    })
  }

  const queue = () => {
    if (reduceMotion || active >= frames.length - 1) {
      // The take rests on its last frame — the audit is the closing beat.
      if (active >= frames.length - 1) later(DWELL_MS, hideCursor)
      return
    }
    later(DWELL_MS, advance)
  }

  steps.forEach((step, i) =>
    step.addEventListener("click", () => {
      stop()
      hideCursor()
      show(i)
    })
  )
  if (replay)
    replay.addEventListener("click", () => {
      stop()
      if (cursor && !reduceMotion) {
        // Restart the cursor from a neutral spot so the first travel reads.
        cursor.style.transition = "none"
        placeAt(cursor, {x: 55, y: 78})
      }
      show(0)
      queue()
    })

  show(0)
  if (reduceMotion) return

  if (cursor) {
    cursor.style.transition = "none"
    placeAt(cursor, {x: 55, y: 78})
  }

  let started = false
  const start = () => {
    if (started) return
    started = true
    queue()
  }
  if (!("IntersectionObserver" in window)) {
    start()
    return
  }
  const io = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        io.disconnect()
        start()
      }
    },
    {threshold: 0.35}
  )
  io.observe(root)
}

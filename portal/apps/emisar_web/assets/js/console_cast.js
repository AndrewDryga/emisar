// Auto-advancing console screencasts (the /security approval-loop section) —
// a "watch the console work" without a video file or a player library, same
// reasoning as terminal_cast.js. Marketing pages are controller-rendered with
// no LiveSocket, so this is a plain DOM module. CSP-safe: bundled in
// marketing.js (script-src 'self'), never inline, no innerHTML.
//
// Progressive enhancement: the server renders the full storyboard — every
// frame with its step label and caption — so no-JS visitors and crawlers get
// the whole story stacked. Here we collapse the storyboard into one stacked
// stage (all frames in a single grid cell), reveal the step tabs + Replay,
// and crossfade through the frames once the cast scrolls into view, ending on
// the last frame. A tab click takes manual control and stops the autoplay.
// Honors prefers-reduced-motion: no autoplay, instant swaps, tabs still work.

const DWELL_MS = 4200

export function initConsoleCasts() {
  document.querySelectorAll("[data-console-cast]").forEach(setupCast)
}

function setupCast(root) {
  const stage = root.querySelector("[data-cast-stage]")
  const frames = Array.from(root.querySelectorAll("[data-cast-frame]"))
  const steps = Array.from(root.querySelectorAll("[data-cast-step]"))
  const stepsWrap = root.querySelector("[data-cast-steps]")
  const replay = root.querySelector("[data-cast-replay]")
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
  let timer = null

  const show = (index) => {
    active = index
    frames.forEach((frame, i) => {
      frame.classList.toggle("opacity-0", i !== index)
      frame.classList.toggle("pointer-events-none", i !== index)
      frame.setAttribute("aria-hidden", String(i !== index))
    })
    steps.forEach((step, i) => step.setAttribute("aria-selected", String(i === index)))
  }

  const stop = () => {
    if (timer) {
      clearTimeout(timer)
      timer = null
    }
  }

  // Advance until the last frame, then rest there — the closing beat (the
  // audit trail) is the message; Replay runs it again.
  const queue = () => {
    stop()
    if (reduceMotion || active >= frames.length - 1) return
    timer = setTimeout(() => {
      show(active + 1)
      queue()
    }, DWELL_MS)
  }

  steps.forEach((step, i) =>
    step.addEventListener("click", () => {
      stop()
      show(i)
    })
  )
  if (replay)
    replay.addEventListener("click", () => {
      show(0)
      queue()
    })

  show(0)
  if (reduceMotion) return

  if (!("IntersectionObserver" in window)) {
    queue()
    return
  }
  let started = false
  const io = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting) && !started) {
        started = true
        io.disconnect()
        queue()
      }
    },
    {threshold: 0.35}
  )
  io.observe(root)
}

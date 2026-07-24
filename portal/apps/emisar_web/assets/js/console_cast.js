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
// stage and PLAY the take once it scrolls into view. Each frame's beat: its
// spotlights play in sequence (each dims everything except the one element
// that matters, with a short label pinned to it), then the overlay cursor
// travels to the frame's declared click point, a ripple fires, and the next
// frame crossfades in — the transitions read as the real interaction that
// produced the captures (which they were: the frames come from a live driven
// session, tools/internal/browser/docs.go captureLoopTake). A tab click
// takes manual control (the frame + its first spotlight, no autoplay);
// Replay runs the take again. Honors prefers-reduced-motion: no autoplay, no
// cursor, instant swaps, tabs still work, spotlights still shown.

// The rhythm per spotlight: in → read → out; then travel → click → swap.
const SPOT_IN_MS = 450
const SPOT_HOLD_MS = 2400
const SPOT_OUT_MS = 350
const TRAVEL_MS = 550
const CLICK_MS = 420
const PLAIN_DWELL_MS = 1800
// Breathing room between the spotlighted element and the ring, as percentages
// of the frame — a hole that hugs the content reads cramped.
const SPOT_PAD_X = 0.7
const SPOT_PAD_Y = 1.0

export function initConsoleCasts() {
  document.querySelectorAll("[data-console-cast]").forEach(setupCast)
}

function parsePoint(value) {
  if (!value) return null
  const [x, y] = value.split(",").map((part) => parseFloat(part))
  return Number.isFinite(x) && Number.isFinite(y) ? {x, y} : null
}

function parseRect(value) {
  if (!value) return null
  const [x, y, w, h] = value.split(",").map((part) => parseFloat(part))
  return [x, y, w, h].every(Number.isFinite) ? {x, y, w, h} : null
}

function setupCast(root) {
  const stage = root.querySelector("[data-cast-stage]")
  const frames = Array.from(root.querySelectorAll("[data-cast-frame]"))
  const steps = Array.from(root.querySelectorAll("[data-cast-step]"))
  const stepsWrap = root.querySelector("[data-cast-steps]")
  const replay = root.querySelector("[data-cast-replay]")
  const cursor = root.querySelector("[data-cast-cursor]")
  const ripple = root.querySelector("[data-cast-ripple]")
  const rippleRing = root.querySelector("[data-cast-ripple-ring]")
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

  const spotsOf = (frame) => Array.from(frame.querySelectorAll("[data-cast-spot]"))

  // Position + reveal one spotlight (padded around its target rect); the
  // label pins above or below whichever edge has room, and drops on phones
  // where a pill would cover the ~340px frame it annotates.
  const revealSpot = (spot) => {
    const rect = parseRect(spot.dataset.spot)
    if (!rect) return
    const x = rect.x - SPOT_PAD_X
    const y = rect.y - SPOT_PAD_Y
    spot.style.left = x + "%"
    spot.style.top = y + "%"
    spot.style.width = rect.w + 2 * SPOT_PAD_X + "%"
    spot.style.height = rect.h + 2 * SPOT_PAD_Y + "%"
    const label = spot.querySelector("[data-cast-spot-label]")
    if (label) {
      label.hidden = imageBox().width < 480
      const above = y > 14
      label.style.top = above ? "auto" : "100%"
      label.style.bottom = above ? "100%" : "auto"
      label.style.marginTop = above ? "0" : "8px"
      label.style.marginBottom = above ? "8px" : "0"
    }
    spot.hidden = false
    later(reduceMotion ? 0 : SPOT_IN_MS, () => spot.classList.remove("opacity-0"))
  }

  const hideSpots = (instant) => {
    frames.forEach((frame) =>
      spotsOf(frame).forEach((spot) => {
        spot.classList.add("opacity-0")
        if (instant) spot.hidden = true
      })
    )
  }

  // Swap to a frame without any spotlight (the autoplay/manual paths choose
  // how to light it afterwards).
  const showFrame = (index) => {
    active = index
    hideSpots(true)
    frames.forEach((frame, i) => {
      frame.classList.toggle("opacity-0", i !== index)
      frame.classList.toggle("pointer-events-none", i !== index)
      frame.setAttribute("aria-hidden", String(i !== index))
    })
    steps.forEach((step, i) => step.setAttribute("aria-selected", String(i === index)))
  }

  const hideCursor = () => {
    if (cursor) {
      cursor.hidden = true
      cursor.classList.add("opacity-0")
    }
    if (ripple) ripple.hidden = true
  }

  const clickRipple = (point) => {
    if (!ripple || !rippleRing) return
    placeAt(ripple, point)
    ripple.hidden = false
    rippleRing.classList.add("animate-ping")
    later(CLICK_MS, () => {
      rippleRing.classList.remove("animate-ping")
      ripple.hidden = true
    })
  }

  // Play a frame's spotlights in sequence, then hand off.
  const playSpots = (frame, done) => {
    const spots = spotsOf(frame)
    if (!spots.length) {
      later(PLAIN_DWELL_MS, done)
      return
    }
    let i = 0
    const next = () => {
      if (i >= spots.length) {
        done()
        return
      }
      const spot = spots[i++]
      revealSpot(spot)
      later(SPOT_IN_MS + SPOT_HOLD_MS, () => {
        spot.classList.add("opacity-0")
        later(SPOT_OUT_MS, next)
      })
    }
    next()
  }

  // The autoplay loop: light the current frame, then travel + click into the
  // next one. The take rests on its last frame — the evidence is the closing
  // beat, replayable from the footer.
  const run = () => {
    playSpots(frames[active], () => {
      if (active >= frames.length - 1) {
        later(600, hideCursor)
        return
      }
      const click = parsePoint(frames[active].dataset.click)
      if (!click || !cursor) {
        showFrame(active + 1)
        run()
        return
      }
      cursor.hidden = false
      cursor.style.transition = `left ${TRAVEL_MS}ms cubic-bezier(0.4, 0, 0.2, 1), top ${TRAVEL_MS}ms cubic-bezier(0.4, 0, 0.2, 1), opacity 200ms`
      cursor.classList.remove("opacity-0")
      placeAt(cursor, click)
      later(TRAVEL_MS + 60, () => {
        clickRipple(click)
        later(CLICK_MS - 60, () => {
          showFrame(active + 1)
          run()
        })
      })
    })
  }

  // Manual view of a frame: the frame plus its first spotlight, held.
  const showManual = (index) => {
    showFrame(index)
    const first = spotsOf(frames[index])[0]
    if (first) revealSpot(first)
  }

  steps.forEach((step, i) =>
    step.addEventListener("click", () => {
      stop()
      hideCursor()
      showManual(i)
    })
  )
  if (replay)
    replay.addEventListener("click", () => {
      stop()
      if (cursor && !reduceMotion) {
        // Restart the cursor from a neutral spot so the first travel reads.
        cursor.style.transition = "none"
        placeAt(cursor, {x: 55, y: 82})
      }
      showFrame(0)
      if (reduceMotion) {
        showManual(0)
      } else {
        run()
      }
    })

  showManual(0)
  if (reduceMotion) return

  if (cursor) {
    cursor.style.transition = "none"
    placeAt(cursor, {x: 55, y: 82})
  }

  let started = false
  const start = () => {
    if (started) return
    started = true
    hideSpots(true)
    run()
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

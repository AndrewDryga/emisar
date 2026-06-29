// Marketing mobile-nav lattice — the blueprint grid drawing itself in.
//
// When the drawer opens, a 45° wavefront sweeps from the gate mark (top-left) toward the
// bottom-right, and each grid line draws in as the front crosses it — horizontals growing
// left-to-right, verticals top-to-bottom — so the whole grid plots in in one clean,
// organized diagonal pass. Settles into a faint grid of lines, in the hero's restrained
// key.
//
// One <canvas>; the loop stops once the wavefront has crossed everything. Grid lines are
// phased off the page nav's height so they match the hero's grid below the nav, and run
// full-bleed under the transparent bar. prefers-reduced-motion paints the grid settled,
// no motion. No-ops when the markup is absent.

const SPACING = 72 // px — grid cell, matching the hero's .contract-grid
const GRID = "39, 39, 42" // blueprint line — matches .contract-grid
const GRID_H = 0.42 // horizontal line alpha
const GRID_V = 0.52 // vertical line alpha
const SWEEP_MS = 1500 // time for the wavefront to cross the whole grid

const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x)

export function initMobileNavLattice() {
  const panel = document.getElementById("marketing-mobile-nav")
  const canvas = document.getElementById("mobile-nav-lattice")
  if (!panel || !canvas) return
  const ctx = canvas.getContext("2d")
  if (!ctx) return

  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)")
  let segs = []
  let view = {w: 0, h: 0}
  let yOffset = 0 // px — grid phase, so a line lands where the bar meets the body
  let maxFront = 1 // x+y the wavefront must reach to finish
  let raf = 0
  let start = null

  // Lay out the grid segments, each tagged with `front` = the x+y of the end the
  // wavefront reaches first (its left/top end), so it draws in diagonal order. One extra
  // row above the top so the vertical lines reach up under the bar.
  const build = (w, h) => {
    segs = []
    maxFront = 1
    const cols = Math.ceil(w / SPACING) + 1
    const rows = Math.ceil(h / SPACING) + 1
    for (let r = -1; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = c * SPACING
        const y = yOffset + r * SPACING
        const front = x + y
        segs.push({x, y, dx: SPACING, dy: 0, kind: "h", front})
        segs.push({x, y, dx: 0, dy: SPACING, kind: "v", front})
        if (front > maxFront) maxFront = front
      }
    }
    maxFront += SPACING // so the last segment finishes growing too
  }

  const size = () => {
    // Phase off the page nav's height so a grid line lands where the bar meets the body.
    const nav = document.querySelector("header")
    yOffset = (nav ? nav.offsetHeight : 0) % SPACING

    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = canvas.clientWidth
    const h = canvas.clientHeight
    canvas.width = Math.round(w * dpr)
    canvas.height = Math.round(h * dpr)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    view = {w, h}
    build(w, h)
  }

  // Fade the lattice out over the bottom quarter so it never competes with the CTAs.
  const yFade = (y, h) => {
    const edge = h * 0.74
    return y <= edge ? 1 : Math.max(0, 1 - (y - edge) / (h - edge))
  }

  // Draw the grid at the wavefront for `elapsed`; each segment grows as the front passes
  // over it. Returns true while the front hasn't cleared the whole grid.
  const draw = (elapsed) => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)
    ctx.lineWidth = 1
    const front = (elapsed / SWEEP_MS) * maxFront
    for (const s of segs) {
      const p = clamp01((front - s.front) / SPACING)
      if (p <= 0) continue
      const alpha = (s.kind === "h" ? GRID_H : GRID_V) * yFade(s.y + s.dy / 2, h)
      ctx.strokeStyle = `rgba(${GRID}, ${alpha})`
      ctx.beginPath()
      ctx.moveTo(s.x, s.y)
      ctx.lineTo(s.x + s.dx * p, s.y + s.dy * p)
      ctx.stroke()
    }
    return front < maxFront
  }

  const frame = (ts) => {
    if (start === null) start = ts
    raf = draw(ts - start) ? requestAnimationFrame(frame) : 0
  }

  const run = () => {
    size()
    cancelAnimationFrame(raf)
    if (reduce.matches) {
      draw(SWEEP_MS + 1) // settled grid, no motion
      raf = 0
      return
    }
    start = null
    raf = requestAnimationFrame(frame)
  }

  const stop = () => {
    cancelAnimationFrame(raf)
    raf = 0
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.clearRect(0, 0, canvas.width, canvas.height)
  }

  // mobile_nav.js toggles the panel's `hidden` class; mirror that here without
  // coupling the two — sweep on open, clear on close.
  const sync = () => (panel.classList.contains("hidden") ? stop() : run())
  new MutationObserver(sync).observe(panel, {attributes: true, attributeFilter: ["class"]})

  // Re-fit + repaint settled if the device rotates while the drawer is open.
  window.addEventListener("resize", () => {
    if (!panel.classList.contains("hidden")) {
      size()
      draw(SWEEP_MS + 1)
    }
  })

  if (!panel.classList.contains("hidden")) run() // defensive: already open on load
}

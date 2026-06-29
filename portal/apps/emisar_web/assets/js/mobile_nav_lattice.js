// Marketing mobile-nav lattice — the "gate coming online" open animation.
//
// When the drawer opens, the blueprint grid AND the diamond nodes at its crossings
// fade in together in a quiet radial cascade from the gate mark (top-left): each grid
// segment and node blooms as the wavefront reaches it, so the whole surface draws
// itself in rather than popping. Kept in the hero's restrained key. Drawn on one
// <canvas> so ~80 nodes + their links cost a single element and one short rAF burst.
//
// It aligns to the hero: the grid runs full-bleed under a transparent, borderless bar,
// so to keep its lines matching the hero's (whose grid sits below the nav) the lattice
// is phased down by the page nav's measured height — a line then lands where the bar
// meets the body, seamlessly.
//
// The drawer is JS-only to open, so there's no no-canvas case to design for — but
// prefers-reduced-motion still paints the settled lattice with no motion. No-ops when
// the markup is absent.

const SPACING = 72 // px — grid cell, matching the hero's .contract-grid
const NODE = 2.6 // diamond half-extent, px
const STAGGER = 26 // ms between radial rings out from the gate mark
const GROW = 360 // ms each segment/node takes to bloom in
const GRID = "39, 39, 42" // blueprint line — matches .contract-grid
const GRID_H = 0.42 // horizontal line alpha (matches .contract-grid)
const GRID_V = 0.52 // vertical line alpha
const ZINC = "180, 184, 196" // faint node base
const BRAND = "54, 230, 165" // emerald accent — #36E6A5

const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x)

// easeOutBack — a small overshoot so each diamond pops as it lands.
const pop = (t) => {
  const c = 1.70158
  const x = t - 1
  return 1 + (c + 1) * x * x * x + c * x * x
}

export function initMobileNavLattice() {
  const panel = document.getElementById("marketing-mobile-nav")
  const canvas = document.getElementById("mobile-nav-lattice")
  if (!panel || !canvas) return
  const ctx = canvas.getContext("2d")
  if (!ctx) return

  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)")
  let nodes = []
  let view = {w: 0, h: 0}
  let yOffset = 0 // px — grid phase, so a line lands where the bar meets the body (set in size())
  let raf = 0
  let start = null

  // Lay a node on each phased grid crossing, with right/down neighbour refs for the
  // grid segments. One extra row above the top (r = -1) so the vertical lines reach up
  // under the bar. Each node carries its cascade delay (distance from the gate mark) and
  // a stable emerald flag.
  const build = (w, h) => {
    const map = new Map()
    nodes = []
    const cols = Math.ceil(w / SPACING) + 1
    const rows = Math.ceil(h / SPACING) + 1
    for (let r = -1; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const node = {
          x: c * SPACING,
          y: yOffset + r * SPACING,
          c,
          r,
          brand: (c * 7 + (r + 2) * 13) % 11 === 0,
        }
        node.delay = (Math.hypot(node.x, Math.max(0, node.y)) / SPACING) * STAGGER
        nodes.push(node)
        map.set(c + "," + r, node)
      }
    }
    for (const node of nodes) {
      node.right = map.get(node.c + 1 + "," + node.r) || null
      node.down = map.get(node.c + "," + (node.r + 1)) || null
    }
  }

  const size = () => {
    // Phase off the page nav's height so a grid line lands where the bar meets the body
    // (matching the hero's grid, which sits below an equal-height nav).
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

  // Paint one frame at `elapsed` ms; returns true while anything is still blooming.
  const draw = (elapsed) => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)
    ctx.shadowBlur = 0
    ctx.lineWidth = 1

    // Blueprint grid — each segment fades in with the later of its two endpoints.
    for (const node of nodes) {
      const p = clamp01((elapsed - node.delay) / GROW)
      if (p <= 0) continue
      for (const [m, alpha] of [
        [node.right, GRID_H],
        [node.down, GRID_V],
      ]) {
        if (!m) continue
        const lp = Math.min(p, clamp01((elapsed - m.delay) / GROW))
        if (lp <= 0) continue
        ctx.strokeStyle = `rgba(${GRID}, ${alpha * lp * yFade(node.y, h)})`
        ctx.beginPath()
        ctx.moveTo(node.x, node.y)
        ctx.lineTo(m.x, m.y)
        ctx.stroke()
      }
    }

    // Diamond nodes on the crossings, over the grid — emerald accents glow, the rest faint.
    let live = false
    for (const node of nodes) {
      const p = clamp01((elapsed - node.delay) / GROW)
      if (p < 1) live = true
      if (p <= 0) continue
      const a = p * yFade(node.y, h)
      const s = NODE * pop(p)
      if (node.brand) {
        ctx.shadowColor = `rgba(${BRAND}, ${0.6 * a})`
        ctx.shadowBlur = 6
        ctx.fillStyle = `rgba(${BRAND}, ${0.6 * a})`
      } else {
        ctx.shadowBlur = 0
        ctx.fillStyle = `rgba(${ZINC}, ${0.32 * a})`
      }
      ctx.beginPath()
      ctx.moveTo(node.x, node.y - s)
      ctx.lineTo(node.x + s, node.y)
      ctx.lineTo(node.x, node.y + s)
      ctx.lineTo(node.x - s, node.y)
      ctx.closePath()
      ctx.fill()
    }
    ctx.shadowBlur = 0
    return live
  }

  const frame = (ts) => {
    if (start === null) start = ts
    raf = draw(ts - start) ? requestAnimationFrame(frame) : 0
  }

  const run = () => {
    size()
    cancelAnimationFrame(raf)
    if (reduce.matches) {
      draw(1e9) // settled lattice, no motion
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
  // coupling the two — run the cascade on open, clear on close.
  const sync = () => (panel.classList.contains("hidden") ? stop() : run())
  new MutationObserver(sync).observe(panel, {attributes: true, attributeFilter: ["class"]})

  // Re-fit + repaint settled if the device rotates while the drawer is open.
  window.addEventListener("resize", () => {
    if (!panel.classList.contains("hidden")) {
      size()
      draw(1e9)
    }
  })

  if (!panel.classList.contains("hidden")) run() // defensive: already open on load
}

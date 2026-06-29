// Marketing mobile-nav lattice — the "gate coming online" open animation.
//
// When the drawer opens, a grid of diamond nodes lights up in a radial cascade
// from the gate mark (top-left) and wires together with faint emerald links —
// the control plane's network assembling itself over the static blueprint grid.
// Drawn on one <canvas> so ~70 nodes + links cost a single element and one short
// rAF burst, not 70 staggered DOM nodes.
//
// The static `.contract-grid` underneath is shown at rest the instant the menu
// opens ("checkered texture right away"); this only enriches it. The drawer is
// JS-only to open, so there's no no-canvas case to design for — but
// prefers-reduced-motion still paints the settled lattice with no motion.
// No-ops when the markup is absent.

const SPACING = 72 // px — matches .contract-grid background-size, so nodes land on intersections
const NODE = 3.2 // diamond half-extent, px
const STAGGER = 26 // ms between radial rings out from the gate mark
const GROW = 360 // ms each node takes to bloom in
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
  let raf = 0
  let start = null

  // Lay nodes on the grid; each carries its cascade delay (distance from the
  // gate mark at the top-left, so the lattice radiates from it) and a stable
  // emerald flag, plus right/down neighbour refs for the wiring.
  const build = (w, h) => {
    const grid = new Map()
    nodes = []
    const cols = Math.ceil(w / SPACING) + 1
    const rows = Math.ceil(h / SPACING) + 1
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const node = {
          x: c * SPACING,
          y: r * SPACING,
          delay: (Math.hypot(c * SPACING, r * SPACING) / SPACING) * STAGGER,
          brand: (c * 7 + r * 13) % 9 === 0,
          c,
          r,
        }
        nodes.push(node)
        grid.set(c + "," + r, node)
      }
    }
    for (const node of nodes) {
      node.right = grid.get(node.c + 1 + "," + node.r) || null
      node.down = grid.get(node.c + "," + (node.r + 1)) || null
    }
  }

  const size = () => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = canvas.clientWidth
    const h = canvas.clientHeight
    canvas.width = Math.round(w * dpr)
    canvas.height = Math.round(h * dpr)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    view = {w, h}
    build(w, h)
  }

  // Fade the lattice out over the bottom quarter, matching the grid's own mask,
  // so it never competes with the CTAs.
  const yFade = (y, h) => {
    const edge = h * 0.74
    return y <= edge ? 1 : Math.max(0, 1 - (y - edge) / (h - edge))
  }

  // Paint one frame at `elapsed` ms; returns true while any node is still blooming.
  const draw = (elapsed) => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)

    // Emerald wiring under the nodes, each growing from its node toward the
    // right/down neighbour as both bloom in.
    ctx.lineWidth = 1
    for (const node of nodes) {
      const p = clamp01((elapsed - node.delay) / GROW)
      if (p <= 0) continue
      for (const m of [node.right, node.down]) {
        if (!m) continue
        const lp = Math.min(p, clamp01((elapsed - m.delay) / GROW))
        if (lp <= 0) continue
        ctx.strokeStyle = `rgba(${BRAND}, ${0.14 * lp * yFade(node.y, h)})`
        ctx.beginPath()
        ctx.moveTo(node.x, node.y)
        ctx.lineTo(node.x + (m.x - node.x) * lp, node.y + (m.y - node.y) * lp)
        ctx.stroke()
      }
    }

    // Diamond nodes over the wiring — emerald accents glow, the rest are faint.
    let live = false
    for (const node of nodes) {
      const p = clamp01((elapsed - node.delay) / GROW)
      if (p < 1) live = true
      if (p <= 0) continue
      const a = p * yFade(node.y, h)
      const s = NODE * pop(p)
      if (node.brand) {
        ctx.shadowColor = `rgba(${BRAND}, ${0.9 * a})`
        ctx.shadowBlur = 10
        ctx.fillStyle = `rgba(${BRAND}, ${0.95 * a})`
      } else {
        ctx.shadowBlur = 0
        ctx.fillStyle = `rgba(${ZINC}, ${0.5 * a})`
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

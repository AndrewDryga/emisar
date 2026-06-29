// Marketing mobile-nav lattice — a faint "gate coming online" open animation.
//
// When the drawer opens, the grid's intersections light up as diamond nodes in a
// quiet radial cascade from the gate mark (top-left) — a subtle enrichment of the
// static blueprint grid, kept in the hero's restrained key. Drawn on one <canvas>
// so ~70 nodes cost a single element and one short rAF burst, not 70 staggered DOM
// nodes.
//
// It also aligns the texture to the hero: the grid runs full-bleed under the bar, so
// to keep its lines matching the hero's (whose grid sits below an equal-height nav)
// the grid is phased down by the bar's measured height — a line then lands exactly at
// the bar's bottom, and the nodes sit on the phased lines.
//
// The static `.contract-grid` is shown at rest the instant the menu opens; this only
// adds the nodes. The drawer is JS-only to open, so there's no no-canvas case to design
// for — but prefers-reduced-motion still paints the settled nodes with no motion.
// No-ops when the markup is absent.

const SPACING = 72 // px — matches .contract-grid background-size, so nodes land on intersections
const NODE = 2.6 // diamond half-extent, px
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

  const grid = document.getElementById("mobile-nav-grid")
  const bar = panel.querySelector("[data-mobile-nav-bar]")
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)")
  let nodes = []
  let view = {w: 0, h: 0}
  let yOffset = 0 // px — grid phase, so nodes sit on the phased lines (set in size())
  let raf = 0
  let start = null

  // Lay a node on each phased grid intersection; each carries its cascade delay (distance
  // from the gate mark at the top-left, so the lattice radiates from it) and a stable
  // emerald flag for the occasional accent.
  const build = (w, h) => {
    nodes = []
    const cols = Math.ceil(w / SPACING) + 1
    const rows = Math.ceil(h / SPACING) + 1
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = c * SPACING
        const y = yOffset + r * SPACING
        nodes.push({
          x,
          y,
          delay: (Math.hypot(x, y) / SPACING) * STAGGER,
          brand: (c * 7 + r * 13) % 11 === 0,
        })
      }
    }
  }

  const size = () => {
    // Align the texture to the bar: phase the grid down by the bar's height so a line
    // lands at its bottom (matching the hero), and offset the nodes onto those lines.
    const barH = bar ? bar.offsetHeight : 0
    if (grid) grid.style.backgroundPositionY = barH + "px"
    yOffset = barH % SPACING

    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = canvas.clientWidth
    const h = canvas.clientHeight
    canvas.width = Math.round(w * dpr)
    canvas.height = Math.round(h * dpr)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    view = {w, h}
    build(w, h)
  }

  // Fade the nodes out over the bottom quarter, matching the grid's own mask, so they
  // never compete with the CTAs.
  const yFade = (y, h) => {
    const edge = h * 0.74
    return y <= edge ? 1 : Math.max(0, 1 - (y - edge) / (h - edge))
  }

  // Paint one frame at `elapsed` ms; returns true while any node is still blooming.
  const draw = (elapsed) => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)
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
      draw(1e9) // settled nodes, no motion
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

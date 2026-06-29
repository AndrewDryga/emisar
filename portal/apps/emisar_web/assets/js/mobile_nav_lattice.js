// Marketing mobile-nav lattice — a "plotter" open animation.
//
// When the drawer opens, a swarm of pens flies along cubic-bezier arcs on random
// paths and prints the blueprint grid + its diamond nodes as it passes — the gate's
// network being plotted in. The grid inks in each pen's wake (a node lights when a
// pen sweeps near it; a segment draws once both its ends are lit). Several pens cover
// it quickly; a short time budget lights any stragglers so it always finishes clean.
// Settles into the same faint grid + nodes, kept in the hero's restrained key.
//
// One <canvas>; the pen loop stops as soon as everything's inked. Grid lines are
// phased off the page nav's height so they match the hero's grid below the nav, and
// run full-bleed under the transparent bar.
//
// The drawer is JS-only to open, so there's no no-canvas case — but prefers-reduced-
// motion paints the settled lattice with no pens, no motion. No-ops when absent.

const SPACING = 72 // px — grid cell, matching the hero's .contract-grid
const NODE = 2.6 // diamond half-extent, px
const GRID = "39, 39, 42" // blueprint line — matches .contract-grid
const GRID_H = 0.42 // horizontal line alpha
const GRID_V = 0.52 // vertical line alpha
const ZINC = "180, 184, 196" // faint node base
const BRAND = "54, 230, 165" // emerald — #36E6A5 (accents + pens)

const PENS = 6 // plotter heads
const PEN_SPEED = 1150 // px/s along the arc
const INK_RADIUS = 88 // px — a pen lights nodes within this
const RAMP = 260 // ms — a node/segment fades in over this once lit
const BUDGET = 1050 // ms — by now, light any stragglers so it always completes
const TRAIL = 8 // pen comet-tail length

const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x)
const rand = (a, b) => a + Math.random() * (b - a)

// easeOutExpo (fade) + easeOutBack (the diamond's pop) — front-loaded to match the
// route links' .rise-N ease-out so the lattice never lags the content.
const ease = (t) => (t >= 1 ? 1 : 1 - Math.pow(2, -10 * t))
const pop = (t) => {
  const c = 1.70158
  const x = t - 1
  return 1 + (c + 1) * x * x * x + c * x * x
}

const cubic = (p0, p1, p2, p3, t) => {
  const u = 1 - t
  const a = u * u * u
  const b = 3 * u * u * t
  const c = 3 * u * t * t
  const d = t * t * t
  return {x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y}
}

export function initMobileNavLattice() {
  const panel = document.getElementById("marketing-mobile-nav")
  const canvas = document.getElementById("mobile-nav-lattice")
  if (!panel || !canvas) return
  const ctx = canvas.getContext("2d")
  if (!ctx) return

  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)")
  let nodes = []
  let pens = []
  let view = {w: 0, h: 0}
  let yOffset = 0 // px — grid phase, so a line lands where the bar meets the body
  let raf = 0
  let start = null
  let last = 0

  // A node on each phased grid crossing, with right/down neighbours for the segments
  // and a `litAt` (ms when a pen first reached it, or null). One extra row above the
  // top so the vertical lines reach up under the bar.
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
          litAt: null,
        }
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

  // Aim a pen at a random not-yet-lit node (or a random point once all are lit), on a
  // bezier that bows off the straight line for a curved flight rather than a beeline.
  const aim = (pen) => {
    const open = nodes.filter((n) => n.litAt === null)
    const p0 = {x: pen.x, y: pen.y}
    const t = open.length ? open[(Math.random() * open.length) | 0] : {x: rand(0, view.w), y: rand(0, view.h)}
    const p3 = {x: t.x, y: t.y}
    const dx = p3.x - p0.x
    const dy = p3.y - p0.y
    const len = Math.hypot(dx, dy) || 1
    const nx = -dy / len // unit normal, to bow the arc sideways
    const ny = dx / len
    const bow1 = rand(-1, 1) * Math.min(170, len * 0.6)
    const bow2 = rand(-1, 1) * Math.min(170, len * 0.6)
    pen.path = {
      p0,
      p1: {x: p0.x + dx * 0.33 + nx * bow1, y: p0.y + dy * 0.33 + ny * bow1},
      p2: {x: p0.x + dx * 0.66 + nx * bow2, y: p0.y + dy * 0.66 + ny * bow2},
      p3,
      len: len + Math.abs(bow1) + Math.abs(bow2),
    }
    pen.t = 0
  }

  const spawn = () => {
    pens = []
    for (let i = 0; i < PENS; i++) {
      const pen = {x: rand(0, view.w), y: rand(0, view.h * 0.6), trail: []}
      aim(pen)
      pens.push(pen)
    }
  }

  // Advance the pens; light the nodes they sweep; light stragglers once past budget.
  const move = (now, dt) => {
    for (const pen of pens) {
      if (pen.t >= 1) aim(pen)
      pen.t = clamp01(pen.t + (PEN_SPEED * dt) / pen.path.len)
      const pos = cubic(pen.path.p0, pen.path.p1, pen.path.p2, pen.path.p3, pen.t)
      pen.x = pos.x
      pen.y = pos.y
      pen.trail.push({x: pen.x, y: pen.y})
      if (pen.trail.length > TRAIL) pen.trail.shift()
      for (const n of nodes) {
        if (n.litAt === null && Math.hypot(n.x - pen.x, n.y - pen.y) <= INK_RADIUS) n.litAt = now
      }
    }
    if (now >= BUDGET) {
      for (const n of nodes) if (n.litAt === null) n.litAt = now
    }
  }

  // Fade the lattice out over the bottom quarter so it never competes with the CTAs.
  const yFade = (y, h) => {
    const edge = h * 0.74
    return y <= edge ? 1 : Math.max(0, 1 - (y - edge) / (h - edge))
  }

  const prog = (n, now) => (n.litAt === null ? 0 : clamp01((now - n.litAt) / RAMP))

  // Paint one frame; returns true while anything is still inking or any pen is active.
  const draw = (now) => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)
    ctx.shadowBlur = 0
    ctx.lineWidth = 1

    // Blueprint grid — each segment fades with the later of its two endpoints.
    for (const node of nodes) {
      const a = prog(node, now)
      if (a <= 0) continue
      for (const [m, alpha] of [
        [node.right, GRID_H],
        [node.down, GRID_V],
      ]) {
        if (!m) continue
        const seg = ease(Math.min(a, prog(m, now)))
        if (seg <= 0) continue
        ctx.strokeStyle = `rgba(${GRID}, ${alpha * seg * yFade(node.y, h)})`
        ctx.beginPath()
        ctx.moveTo(node.x, node.y)
        ctx.lineTo(m.x, m.y)
        ctx.stroke()
      }
    }

    // Diamond nodes on the crossings — emerald accents glow, the rest faint.
    for (const node of nodes) {
      const p = prog(node, now)
      if (p <= 0) continue
      const a = ease(p) * yFade(node.y, h)
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

    // Pens — an emerald comet (fading tail + glowing head) — only while plotting.
    const plotting = now < BUDGET + RAMP
    if (plotting) {
      ctx.shadowBlur = 0
      for (const pen of pens) {
        for (let i = 1; i < pen.trail.length; i++) {
          ctx.strokeStyle = `rgba(${BRAND}, ${(i / pen.trail.length) * 0.45})`
          ctx.lineWidth = 1.5
          ctx.beginPath()
          ctx.moveTo(pen.trail[i - 1].x, pen.trail[i - 1].y)
          ctx.lineTo(pen.trail[i].x, pen.trail[i].y)
          ctx.stroke()
        }
        ctx.shadowColor = `rgba(${BRAND}, 0.9)`
        ctx.shadowBlur = 10
        ctx.fillStyle = `rgba(${BRAND}, 0.95)`
        ctx.beginPath()
        ctx.arc(pen.x, pen.y, 2.2, 0, Math.PI * 2)
        ctx.fill()
        ctx.shadowBlur = 0
      }
    }

    if (plotting) return true
    for (const n of nodes) if (prog(n, now) < 1) return true
    return false
  }

  const frame = (ts) => {
    if (start === null) {
      start = ts
      last = 0
    }
    const now = ts - start
    const dt = Math.min(now - last, 50) / 1000
    last = now
    move(now, dt)
    raf = draw(now) ? requestAnimationFrame(frame) : 0
  }

  const run = () => {
    size()
    cancelAnimationFrame(raf)
    if (reduce.matches) {
      for (const n of nodes) n.litAt = 0
      draw(BUDGET + RAMP + 1) // settled lattice, no pens
      raf = 0
      return
    }
    spawn()
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
  // coupling the two — plot on open, clear on close.
  const sync = () => (panel.classList.contains("hidden") ? stop() : run())
  new MutationObserver(sync).observe(panel, {attributes: true, attributeFilter: ["class"]})

  // Re-fit + repaint settled if the device rotates while the drawer is open.
  window.addEventListener("resize", () => {
    if (!panel.classList.contains("hidden")) {
      size()
      for (const n of nodes) n.litAt = 0
      draw(BUDGET + RAMP + 1)
    }
  })

  if (!panel.classList.contains("hidden")) run() // defensive: already open on load
}

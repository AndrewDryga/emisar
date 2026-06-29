// Marketing mobile-nav lattice — a quiet "plotter" open animation.
//
// When the drawer opens, a few small heads walk ALONG the grid lines — node to node
// down each edge — drawing the blueprint line they trace, like a plotter following
// the grid. They prefer not-yet-drawn edges, so they fan out and ink the grid in a
// calm walk; whatever they haven't reached by a short time budget simply fades in.
// Diamond nodes light as a head passes a crossing. Settles into the same faint grid +
// nodes, kept in the hero's restrained key — neat and subtle, no wild arcs.
//
// One <canvas>; the loop stops once everything's drawn. Grid lines are phased off the
// page nav's height so they match the hero's grid below the nav, and run full-bleed
// under the transparent bar. prefers-reduced-motion paints it settled, no heads.
// No-ops when the markup is absent.

const SPACING = 72 // px — grid cell, matching the hero's .contract-grid
const NODE = 2.6 // diamond half-extent, px
const GRID = "39, 39, 42" // blueprint line — matches .contract-grid
const GRID_H = 0.42 // horizontal line alpha
const GRID_V = 0.52 // vertical line alpha
const ZINC = "180, 184, 196" // faint node base
const BRAND = "54, 230, 165" // emerald — #36E6A5 (accents + heads)

const HEADS = 5 // plotter heads
const SPEED = 820 // px/s along an edge — a calm glide
const RAMP = 280 // ms — a node / budget-filled segment fades in over this
const BUDGET = 1300 // ms — by now, fade in whatever the heads haven't reached

const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x)

// easeOutExpo (fade) + easeOutBack (the diamond's pop) — front-loaded to match the
// route links' .rise-N ease-out, so the lattice never lags the content.
const ease = (t) => (t >= 1 ? 1 : 1 - Math.pow(2, -10 * t))
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
  let edges = []
  let heads = []
  let view = {w: 0, h: 0}
  let yOffset = 0 // px — grid phase, so a line lands where the bar meets the body
  let raf = 0
  let start = null
  let last = 0

  // Build the grid graph: a node on each phased crossing, plus a shared edge object
  // per right/down link (geometric draw progress + which end it's drawn from). One
  // extra row above the top so the vertical lines reach up under the bar.
  const build = (w, h) => {
    const map = new Map()
    nodes = []
    edges = []
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
          links: [],
        }
        nodes.push(node)
        map.set(c + "," + r, node)
      }
    }
    const link = (a, b, kind) => {
      const e = {a, b, kind, drawn: 0, from: null, fadeAt: null}
      edges.push(e)
      a.links.push({to: b, edge: e})
      b.links.push({to: a, edge: e})
    }
    for (const n of nodes) {
      const right = map.get(n.c + 1 + "," + n.r)
      const down = map.get(n.c + "," + (n.r + 1))
      if (right) link(n, right, "h")
      if (down) link(n, down, "v")
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

  // Point a head down a fresh edge from its current node — prefer an undrawn one so the
  // heads keep inking new lines; otherwise wander down any edge to reach new ground.
  const route = (head) => {
    const links = head.at.links
    if (!links.length) return
    const open = links.filter((l) => l.edge.drawn === 0 && l.edge.fadeAt === null)
    const pool = open.length ? open : links
    const l = pool[(Math.random() * pool.length) | 0]
    head.edge = l.edge
    head.next = l.to
    head.t = 0
    if (l.edge.drawn === 0 && l.edge.fadeAt === null) l.edge.from = head.at
  }

  const spawn = () => {
    heads = []
    for (let i = 0; i < HEADS; i++) {
      const at = nodes[(Math.random() * nodes.length) | 0]
      at.litAt = 0
      const head = {at, next: at, edge: null, t: 1, x: at.x, y: at.y}
      route(head)
      heads.push(head)
    }
  }

  const move = (now, dt) => {
    const step = (SPEED * dt) / SPACING
    for (const head of heads) {
      if (!head.edge) {
        route(head)
        if (!head.edge) continue
      }
      head.t += step
      if (head.edge.from === head.at && head.edge.drawn < 1) {
        head.edge.drawn = clamp01(head.t)
      }
      if (head.t >= 1) {
        if (head.edge.from === head.at) head.edge.drawn = 1
        head.at = head.next
        if (head.at.litAt === null) head.at.litAt = now
        route(head)
      }
      const tt = head.t < 1 ? head.t : 1
      head.x = head.at.x + (head.next.x - head.at.x) * tt
      head.y = head.at.y + (head.next.y - head.at.y) * tt
    }
    if (now >= BUDGET) {
      for (const e of edges) if (e.drawn === 0 && e.fadeAt === null) e.fadeAt = now
      for (const n of nodes) if (n.litAt === null) n.litAt = now
    }
  }

  // Fade the lattice out over the bottom quarter so it never competes with the CTAs.
  const yFade = (y, h) => {
    const edge = h * 0.74
    return y <= edge ? 1 : Math.max(0, 1 - (y - edge) / (h - edge))
  }

  const draw = (now) => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)
    ctx.shadowBlur = 0
    ctx.lineWidth = 1

    // Blueprint grid — pen-traced edges grow from their entry end; the rest fades in.
    for (const e of edges) {
      const alpha = (e.kind === "h" ? GRID_H : GRID_V) * yFade((e.a.y + e.b.y) / 2, h)
      if (e.drawn > 0) {
        const s = e.from || e.a
        const o = s === e.a ? e.b : e.a
        ctx.strokeStyle = `rgba(${GRID}, ${alpha})`
        ctx.beginPath()
        ctx.moveTo(s.x, s.y)
        ctx.lineTo(s.x + (o.x - s.x) * e.drawn, s.y + (o.y - s.y) * e.drawn)
        ctx.stroke()
      } else if (e.fadeAt !== null) {
        const f = ease(clamp01((now - e.fadeAt) / RAMP))
        if (f <= 0) continue
        ctx.strokeStyle = `rgba(${GRID}, ${alpha * f})`
        ctx.beginPath()
        ctx.moveTo(e.a.x, e.a.y)
        ctx.lineTo(e.b.x, e.b.y)
        ctx.stroke()
      }
    }

    // Diamond nodes on the crossings — emerald accents glow softly, the rest faint.
    for (const n of nodes) {
      if (n.litAt === null) continue
      const p = clamp01((now - n.litAt) / RAMP)
      const a = ease(p) * yFade(n.y, h)
      const s = NODE * pop(p)
      if (n.brand) {
        ctx.shadowColor = `rgba(${BRAND}, ${0.6 * a})`
        ctx.shadowBlur = 6
        ctx.fillStyle = `rgba(${BRAND}, ${0.6 * a})`
      } else {
        ctx.shadowBlur = 0
        ctx.fillStyle = `rgba(${ZINC}, ${0.32 * a})`
      }
      ctx.beginPath()
      ctx.moveTo(n.x, n.y - s)
      ctx.lineTo(n.x + s, n.y)
      ctx.lineTo(n.x, n.y + s)
      ctx.lineTo(n.x - s, n.y)
      ctx.closePath()
      ctx.fill()
    }

    // Heads — a small dim emerald dot at each pen tip, only while plotting.
    if (now < BUDGET + RAMP) {
      ctx.shadowColor = `rgba(${BRAND}, 0.5)`
      ctx.shadowBlur = 4
      ctx.fillStyle = `rgba(${BRAND}, 0.85)`
      for (const head of heads) {
        ctx.beginPath()
        ctx.arc(head.x, head.y, 1.6, 0, Math.PI * 2)
        ctx.fill()
      }
      ctx.shadowBlur = 0
      return true
    }
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
      for (const e of edges) e.drawn = 1
      draw(BUDGET + RAMP + 1) // settled, no heads
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
      for (const e of edges) e.drawn = 1
      draw(BUDGET + RAMP + 1)
    }
  })

  if (!panel.classList.contains("hidden")) run() // defensive: already open on load
}

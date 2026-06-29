// Marketing mobile-nav lattice — a quiet "plotter" open animation.
//
// When the drawer opens, the blueprint grid draws itself in: a few unseen plotter heads
// walk ALONG the grid lines — node to node down each edge — and each line grows behind
// the head tracing it. When a head runs out of undrawn neighbours it routes (shortest
// path along the grid) to the nearest line still missing and keeps going, so together
// they trace the ENTIRE grid before stopping. Settles into a faint grid of lines, in the
// hero's restrained key — neat and subtle, only the lines moving.
//
// One <canvas>; the loop stops once every edge is drawn. Grid lines are phased off the
// page nav's height so they match the hero's grid below the nav, and run full-bleed under
// the transparent bar. prefers-reduced-motion paints the grid settled, no motion.
// No-ops when the markup is absent.

const SPACING = 72 // px — grid cell, matching the hero's .contract-grid
const GRID = "39, 39, 42" // blueprint line — matches .contract-grid
const GRID_H = 0.42 // horizontal line alpha
const GRID_V = 0.52 // vertical line alpha

const HEADS = 8 // plotter heads
const SPEED = 1200 // px/s along an edge — quick but still a glide

const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x)

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
  let lastTs = null

  // Build the grid graph: a node on each phased crossing, plus a shared edge object per
  // right/down link (geometric draw progress + which end it's drawn from). One extra row
  // above the top so the vertical lines reach up under the bar.
  const build = (w, h) => {
    const map = new Map()
    nodes = []
    edges = []
    const cols = Math.ceil(w / SPACING) + 1
    const rows = Math.ceil(h / SPACING) + 1
    for (let r = -1; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const node = {x: c * SPACING, y: yOffset + r * SPACING, c, r, links: []}
        nodes.push(node)
        map.set(c + "," + r, node)
      }
    }
    const link = (a, b, kind) => {
      const e = {a, b, kind, drawn: 0, from: null}
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

  // Shortest path (along the grid) from `from` to the nearest node that still has an
  // undrawn edge — the route a head walks to reach the next line to draw. [] if none.
  const routeToUndrawn = (from) => {
    const prev = new Map([[from, null]])
    const queue = [from]
    for (let i = 0; i < queue.length; i++) {
      const n = queue[i]
      if (n !== from && n.links.some((l) => l.edge.drawn === 0)) {
        const path = []
        for (let cur = n; cur !== from; cur = prev.get(cur)) path.unshift(cur)
        return path
      }
      for (const l of n.links) if (!prev.has(l.to)) prev.set(l.to, n), queue.push(l.to)
    }
    return []
  }

  // Aim a head down its next edge: an undrawn neighbour if any (draw it), else the next
  // step of a planned walk to the nearest undrawn line. False once nothing's left.
  const nextEdge = (head) => {
    const open = head.at.links.filter((l) => l.edge.drawn === 0)
    if (open.length) {
      head.path = null
      const l = open[(Math.random() * open.length) | 0]
      head.edge = l.edge
      head.next = l.to
      head.t = 0
      l.edge.from = head.at
      return true
    }
    if (!head.path || !head.path.length) head.path = routeToUndrawn(head.at)
    if (head.path.length) {
      const to = head.path.shift()
      head.edge = head.at.links.find((l) => l.to === to).edge
      head.next = to
      head.t = 0
      return true
    }
    head.done = true
    return false
  }

  const spawn = () => {
    heads = []
    for (let i = 0; i < HEADS; i++) {
      const at = nodes[(Math.random() * nodes.length) | 0]
      const head = {at, next: at, edge: null, t: 0, path: null, done: false}
      nextEdge(head)
      heads.push(head)
    }
  }

  const move = (dt) => {
    const stepLen = (SPEED * dt) / SPACING
    for (const head of heads) {
      if (head.done) continue
      if (!head.edge && !nextEdge(head)) continue
      head.t += stepLen
      if (head.edge.from === head.at && head.edge.drawn < 1) head.edge.drawn = clamp01(head.t)
      if (head.t >= 1) {
        if (head.edge.from === head.at) head.edge.drawn = 1
        head.at = head.next
        nextEdge(head)
      }
    }
  }

  // Fade the lattice out over the bottom quarter so it never competes with the CTAs.
  const yFade = (y, h) => {
    const edge = h * 0.74
    return y <= edge ? 1 : Math.max(0, 1 - (y - edge) / (h - edge))
  }

  // Draw the grid; each edge grows from the end its head entered. True while any line
  // is still being traced.
  const draw = () => {
    const {w, h} = view
    ctx.clearRect(0, 0, w, h)
    ctx.lineWidth = 1
    let plotting = false
    for (const e of edges) {
      if (e.drawn < 1) plotting = true
      if (e.drawn <= 0) continue
      const s = e.from || e.a
      const o = s === e.a ? e.b : e.a
      const alpha = (e.kind === "h" ? GRID_H : GRID_V) * yFade((e.a.y + e.b.y) / 2, h)
      ctx.strokeStyle = `rgba(${GRID}, ${alpha})`
      ctx.beginPath()
      ctx.moveTo(s.x, s.y)
      ctx.lineTo(s.x + (o.x - s.x) * e.drawn, s.y + (o.y - s.y) * e.drawn)
      ctx.stroke()
    }
    return plotting
  }

  const frame = (ts) => {
    if (lastTs === null) lastTs = ts
    const dt = Math.min(ts - lastTs, 50) / 1000
    lastTs = ts
    move(dt)
    raf = draw() ? requestAnimationFrame(frame) : 0
  }

  const run = () => {
    size()
    cancelAnimationFrame(raf)
    if (reduce.matches) {
      for (const e of edges) e.drawn = 1
      draw() // settled grid, no motion
      raf = 0
      return
    }
    spawn()
    lastTs = null
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
      for (const e of edges) e.drawn = 1
      draw()
    }
  })

  if (!panel.classList.contains("hidden")) run() // defensive: already open on load
}

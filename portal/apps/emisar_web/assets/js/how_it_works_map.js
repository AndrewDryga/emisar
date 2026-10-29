// The animated "How it works" map on /how-it-works: ten steps in four acts (Before, Set up,
// Requests, Record) that play on their own, narrated above the drawing, with Previous,
// Pause/Play, and Next beside the narration.
//
// Marketing pages are controller-rendered (no LiveSocket), so this runs as a plain DOM module on
// load, like the terminal demo. Progressive enhancement: the server renders the finished picture
// (the record step) and every step's caption, so no-JS visitors and crawlers get the whole story.
// Here a small model replays each step as a timed sequence of what appears, lights, and travels
// along the wires. Like a video player, hovering never pauses; Pause and scrolling away do.
// Reduced motion shows settled frames only, and Play steps through them.

const SPEED = 0.14 // px per ms: slow enough to follow; a 96 px lane takes about 700 ms
const HOP = [450, 1100] // ms: the shortest and longest hop, so tiny and long wires stay readable
const HEAD = 34 // px: length of the travelling light
const LEAD = 500 // ms: the narration changes first, then the map moves
const READ_MS = 330 // ms per caption word (about 180 words a minute), never under 3 s
const N = 10
const ACTS = [1, 3, 7, 10]
const ACT_OF = [0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 3]
const WIRES = {
  ssh: ["ag", "sh"],
  mcp: ["ag", "cp-l"],
  tls: ["cp-r", "rn"],
  appr: ["cp-ap", "you"],
  pg: ["rn-1", "pg"],
  ngx: ["rn-2", "ngx"],
  k8s: ["rn-3", "k8s"]
}
const BEFORE = [
  "con",
  "con-a",
  "con-b",
  "a1",
  "a2",
  "a3",
  "b1",
  "b2",
  "b3",
  "chat-a",
  "chat-b",
  "dza1",
  "dza2",
  "dzb1",
  "dzb2",
  "dzb3",
  "key"
]
const SHRUG = '<span class="hiw-shrug">¯\\_(ツ)_/¯</span>'

// Each state: a caption, a start() that clears what the state replaces, the parts it quiets
// (focus: a, b, c columns; dim: wires), and a timed sequence. Steps: a number waits; a function
// changes the model; {w} sends light down a wire (draw: the wire appears as the light passes;
// lit: it stays lit; par: does not wait).
// prettier-ignore
const S = [null,
  // 1 An SSH key
  {
    start: (m, k) => { m.focus = ""; k.text("con-who", "Claude.ai")(); k.text("you-sub", SHRUG)() },
    seq: (k) => [k.show("agent"), 90, k.show("you"), 90, k.show("region"), 300, k.show("con"), 300, k.lit("ag-claude"), { w: "ssh", draw: 1, lit: 1, tone: "rose" }, k.show("key", "con-b"), 300, k.show("b1"), 550, k.show("b2"), 450,
      { w: "ssh", rev: 1, tone: "rose" }, k.show("chat-b"), 650, k.show("b3"), k.lit("svc-pg", "jolt"), 800, k.unlit("svc-pg"), 300,
      k.show("dzb1"), 280, k.show("dzb2"), 280, k.show("dzb3")] },
  // 2 A confused agent
  {
    start: (m, k) => { m.focus = ""; k.hide("con-b", "b1", "b2", "b3", "chat-b", "dzb1", "dzb2", "dzb3")(); k.text("con-who", "Claude.ai")(); k.text("you-sub", SHRUG)() },
    seq: (k) => [300, k.lit("ag-claude"), k.show("chat-a"), 900, { w: "ssh", tone: "rose" }, k.show("con-a"), k.show("a1"), 700, k.show("a2"), k.lit("a2"), 800,
      k.show("a3"), k.lit("svc-pg", "jolt"), 900, k.unlit("svc-pg", "a2"), 300, k.show("dza1"), 280, k.show("dza2")] },
  // 3 Install the runner
  {
    start: (m, k) => { m.focus = "a"; k.hide(...BEFORE)(); k.unwire("ssh")(); k.text("you-sub", "")(); k.text("con-who", "you")() },
    seq: (k) => [200, k.show("con", "con-c"), k.live("you"), 250, k.show("c1"), 900, k.show("c2"), 800, k.show("c3"), 800, k.show("c4"), 1300,
      k.hide("con", "con-c", "c1", "c2", "c3", "c4"), k.unlive("you"), k.text("rn-st", "starting"), k.show("runner")] },
  // 4 emisar in the middle
  {
    start: (m) => { m.focus = "a"; m.glow = 1 },
    seq: (k) => [100, k.show("cp", "cp-h"), 340, k.show("r-id"), k.flash("r-id"), 200, k.show("r-pol"), k.flash("r-pol"), 200, k.show("r-ap"), k.flash("r-ap"), 200, k.show("r-au", "evs"), k.flash("r-au"), 500, { w: "tls", rev: 1, draw: 1, lit: 1 }, k.show("lb-tls"), k.ports("pt-cpr", "pt-rn"), k.dot("rn-dot", 1), k.text("rn-st", "online")] },
  // 5 Connect your agent
  {
    start: (m) => { m.focus = "c"; m.glow = 1; m.terse = 1; m.dimW = ["tls"] },
    seq: (k) => [200, { w: "mcp", draw: 1, lit: 1 }, k.ports("pt-ag", "pt-cpl"), k.show("lb-mcp"), 120, k.show("m-oa1"), 70, k.show("m-oa2"), 70, k.show("m-br"), 200, k.dot("ag-dot", 1), k.text("ag1", "emisar"), k.text("ag2", "connected over MCP"), k.show("ag-st")] },
  // 6 Add packs
  {
    start: (m, k) => { m.focus = "a b"; m.glow = 1; m.dimW = ["mcp"]; k.hide("m-oa1", "m-oa2", "m-br")() },
    seq: (k) => [200, k.show("packs"), 250, k.show("pk1"), 180, k.show("pk2"), { w: "pg", draw: 1, par: 1 }, 180, k.show("pk3"), { w: "ngx", draw: 1, par: 1 }, 180, k.show("pk4"), { w: "k8s", draw: 1, par: 1 }] },
  // 7 A request runs
  {
    start: (m) => { m.focus = ""; m.glow = 1 },
    seq: (k) => k.request({ id: "postgres.slow_queries", tier: "low", ev: "ev1", decide: "pass" }) },
  // 8 A person approves
  {
    start: (m, k) => { m.focus = ""; m.glow = 1; k.text("you-sub", "Console or email")() },
    seq: (k) => k.request({ id: "postgres.terminate_backend", tier: "high", ev: "ev2", decide: "warn" }) },
  // 9 Refused
  {
    start: (m) => { m.focus = "c"; m.glow = 1; m.dimW = ["tls", "pg", "ngx", "k8s"] },
    seq: (k) => k.request({ id: "linux.reboot_host", tier: "critical", ev: "ev3", decide: "deny" }) },
  // 10 On the record
  { last: 1000,
    start: (m) => { m.focus = ""; m.glow = 1 },
    seq: (k) => [300, k.lit("r-au"), k.lit("evs"), 180, k.lit("ev1"), 130, k.lit("ev2"), 130, k.lit("ev3"), 450, k.text("rl0", "journal · hash-chained"), k.text("rl1", '<span class="jd"></span>postgres.slow_queries'), k.text("rl2", '<span class="jd"></span>postgres.terminate_backend'), k.lit("term"), 300, k.text("ag1", "emisar"), k.text("ag2", "connected over MCP")] }
]

function init(root) {
  const stage = root.querySelector("[data-hiw-stage]")
  const svg = root.querySelector("[data-hiw-wires]")
  const cap = root.querySelector("[data-hiw-cap]")
  const capSrc = [...root.querySelectorAll("[data-hiw-cap-n]")]
  const acts = [...root.querySelectorAll("[data-hiw-act]")]
  const segs = [...root.querySelectorAll("[data-hiw-seg]")]
  const playBtn = root.querySelector("[data-hiw-play]")
  const playLabel = root.querySelector("[data-hiw-play-label]")
  const prevBtn = root.querySelector("[data-hiw-prev]")
  const nextBtn = root.querySelector("[data-hiw-next]")
  const countEl = root.querySelector("[data-hiw-count]")
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)")
  const els = {}
  root.querySelectorAll("[data-k]").forEach((el) => {
    ;(els[el.dataset.k] ||= []).push(el)
  })
  const all = (key) => els[key] || []

  // ---- wires -------------------------------------------------------------------------------
  const NS = "http://www.w3.org/2000/svg"
  const wires = {}
  svg.replaceChildren() // a remount starts clean
  for (const id of Object.keys(WIRES)) {
    const mk = (cls) => {
      const p = document.createElementNS(NS, "path")
      p.setAttribute("class", cls)
      svg.appendChild(p)
      return p
    }
    wires[id] = {
      id,
      base: mk("hiw-w"),
      lit: mk("hiw-w-lit"),
      head: mk("hiw-w-head"),
      L: 0,
      busy: null
    }
  }
  // Layout position (offset chain), so entrance transforms never bend a wire.
  const port = (name) => {
    const el = [...root.querySelectorAll('[data-port="' + name + '"]')].find((x) => x.offsetParent)
    if (!el) return null
    let x = el.offsetWidth / 2,
      y = el.offsetHeight / 2,
      n = el
    while (n && n !== stage) {
      x += n.offsetLeft
      y += n.offsetTop
      n = n.offsetParent
    }
    if (n !== stage) return null
    const c = el.classList
    const side = c.contains("p-l") ? "l" : c.contains("p-r") ? "r" : c.contains("p-t") ? "t" : "b"
    return {x: Math.round(x * 2) / 2, y: Math.round(y * 2) / 2, side}
  }
  const rounded = (pts, rad) => {
    let d = "M" + pts[0].x + " " + pts[0].y
    for (let i = 1; i < pts.length - 1; i++) {
      const a = pts[i - 1],
        p = pts[i],
        b = pts[i + 1]
      const l1 = Math.hypot(p.x - a.x, p.y - a.y),
        l2 = Math.hypot(b.x - p.x, b.y - p.y)
      const r = Math.min(rad, l1 / 2, l2 / 2)
      const ux = (p.x - a.x) / l1,
        uy = (p.y - a.y) / l1,
        vx = (b.x - p.x) / l2,
        vy = (b.y - p.y) / l2
      d +=
        " L" +
        (p.x - ux * r) +
        " " +
        (p.y - uy * r) +
        " Q" +
        p.x +
        " " +
        p.y +
        " " +
        (p.x + vx * r) +
        " " +
        (p.y + vy * r)
    }
    const z = pts[pts.length - 1]
    return d + " L" + z.x + " " + z.y
  }
  const route = (a, b) => {
    const H = (s) => s === "l" || s === "r"
    if (H(a.side) && H(b.side)) {
      if (Math.abs(a.y - b.y) < 2) return "M" + a.x + " " + a.y + " L" + b.x + " " + a.y
      const mx = (a.x + b.x) / 2
      return rounded([a, {x: mx, y: a.y}, {x: mx, y: b.y}, b], 12)
    }
    if (!H(a.side) && !H(b.side)) {
      if (Math.abs(a.x - b.x) < 2) return "M" + a.x + " " + a.y + " L" + a.x + " " + b.y
      const my = (a.y + b.y) / 2
      return rounded([a, {x: a.x, y: my}, {x: b.x, y: my}, b], 12)
    }
    return H(a.side) ? rounded([a, {x: b.x, y: a.y}, b], 12) : rounded([a, {x: a.x, y: b.y}, b], 12)
  }
  const span = (p, L, a, b) => {
    a = Math.max(0, a)
    b = Math.min(L, b)
    if (b - a < 0.5) {
      p.style.strokeDasharray = "0 " + (L * 2 + 10)
      p.style.strokeDashoffset = "0"
      return
    }
    p.style.strokeDasharray = b - a + " " + (L * 2 + 10)
    p.style.strokeDashoffset = String(-a)
  }
  const full = (p) => {
    p.style.strokeDasharray = ""
    p.style.strokeDashoffset = ""
  }
  function layout() {
    const s = stage.getBoundingClientRect()
    svg.setAttribute("viewBox", "0 0 " + s.width + " " + s.height)
    for (const w of Object.values(wires)) {
      const a = port(WIRES[w.id][0]),
        b = port(WIRES[w.id][1])
      if (!a || !b) {
        w.L = 0
        w.base.removeAttribute("d")
        w.lit.removeAttribute("d")
        w.head.removeAttribute("d")
        continue
      }
      const d = route(a, b)
      w.base.setAttribute("d", d)
      w.lit.setAttribute("d", d)
      w.head.setAttribute("d", d)
      w.L = w.base.getTotalLength()
    }
  }

  // ---- the model: everything the drawing shows, as data ---------------------------------------
  const blank = () => ({
    vis: new Set(),
    lit: new Map(),
    live: new Set(),
    ports: new Set(),
    dots: new Set(),
    wires: {},
    focus: "",
    glow: 0,
    terse: 0,
    dimW: [],
    qk: new Set(),
    text: {
      ag1: "",
      ag2: "",
      "you-sub": "",
      "con-who": "you",
      "rn-st": "starting",
      rl0: "runner log",
      rl1: "",
      rl2: ""
    }
  })
  const TRANSIENT = [
    "m-id",
    "pp-pass",
    "pp-warn",
    "pp-deny",
    "m-skip",
    "pa-pass",
    "redact",
    "ask",
    "ask-done"
  ]
  function clearTransient(m) {
    m.lit.clear()
    m.live.clear()
    m.dimW = []
    m.qk.clear()
    TRANSIENT.forEach((k) => m.vis.delete(k))
    m.vis.add("ask-b")
    for (const id in m.wires) m.wires[id].lit = ""
  }
  let model = blank()
  const kit = {
    show:
      (...keys) =>
      () =>
        keys.forEach((k) => model.vis.add(k)),
    hide:
      (...keys) =>
      () =>
        keys.forEach((k) => model.vis.delete(k)),
    lit: (k, tone) => () => model.lit.set(k, tone || "pass"),
    unlit:
      (...keys) =>
      () =>
        keys.forEach((k) => model.lit.delete(k)),
    flash: (k) => ({flash: k}),
    live:
      (...keys) =>
      () =>
        keys.forEach((k) => model.live.add(k)),
    unlive:
      (...keys) =>
      () =>
        keys.forEach((k) => model.live.delete(k)),
    ports:
      (...keys) =>
      () =>
        keys.forEach((k) => model.ports.add(k)),
    dot: (k, on) => () => (on ? model.dots.add(k) : model.dots.delete(k)),
    text: (k, html) => () => {
      model.text[k] = html
    },
    wire: (id, tone) => () => {
      model.wires[id] = {base: tone || "on", lit: ""}
    },
    unwire:
      (...ids) =>
      () =>
        ids.forEach((id) => delete model.wires[id]),
    quiet:
      (...keys) =>
      () =>
        keys.forEach((k) => model.qk.add(k)),
    // One request, end to end. The runner's checks hold 1.2 s and a pending approval 2.5 s; the
    // returned result then holds for the caption's reading time.
    // prettier-ignore
    request(r) {
      const k = kit; const deny = r.decide === "deny"; const warn = r.decide === "warn"
      const steps = [200, k.lit("ag-claude"), k.text("ag1", r.id), k.text("ag2", r.tier + " risk · run_action"), k.dot("ag-dot", 1),
        450, { w: "mcp", lit: 1, tone: deny ? "plain" : "brand" }, k.live("cp"), k.lit("gate"), k.lit("r-id"), k.show("m-id"),
        380, k.lit("r-pol", r.decide), k.show("pp-" + r.decide), 700, k.unlit("gate"), -700]
      if (deny) {
        steps.push(560, k.unlit("r-id"), k.lit("r-au"), k.show(r.ev),
          300, { w: "mcp", rev: 1, tone: "plain" }, k.unlive("cp"), k.unlit("r-au", "ag-claude"), k.text("ag2", "critical risk · refused by policy"),
          200, k.unlit("r-pol"))
        return steps }
      if (warn) {
        steps.push(400, k.unlit("r-id"), k.lit("r-ap"), k.text("ag2", "high risk · waiting for approval"),
          { w: "appr", draw: 1, lit: 1, tone: "plain" }, k.unlive("cp"), k.show("ask"), k.live("ask"),
          2500, k.lit("ask-ok"), 300, k.hide("ask-b"), k.show("ask-done"), k.unlit("ask-ok"),
          400, { w: "appr", rev: 1, lit: 1 }, k.unlive("ask"), k.live("cp"), k.show("pa-pass")) } else {
        steps.push(320, k.show("m-skip")) }
      steps.push(240, k.unlit("r-id", "r-pol", "r-ap"), { w: "tls", lit: 1 }, k.unlive("cp"), k.live("runner"), k.show("term"), k.lit("pk2"), k.text("rl0", "runner log"), k.text("rl1", r.id), k.text("rl2", '<span class="ok">✓</span> trusted pack · local rules'),
        1200, { w: "pg", lit: 1 }, k.unlive("runner"), k.lit("svc-pg"), k.text("rl2", "▸ running on Postgres"),
        450, { w: "pg", rev: 1 }, k.unlit("svc-pg"), k.live("runner"), k.text("rl2", '<span class="ok">✓</span> exit 0 · output redacted'), k.show("redact"),
        480, { w: "tls", rev: 1 }, k.unlive("runner"), k.unlit("pk2"), k.live("cp"), k.lit("r-au"), k.show(r.ev),
        300, { w: "mcp", rev: 1 }, k.unlive("cp"), k.unlit("r-au"), k.text("ag2", r.tier + " risk · " + (warn ? "approved, result back" : "result returned")),
        250, k.unlit("ag-claude"))
      return steps }
  }

  // Replays the settled end of each earlier state, then sets up state n.
  function startModel(n) {
    model = blank()
    for (let i = 1; i < n; i++) {
      clearTransient(model)
      S[i].start(model, kit)
      runInstant(S[i].seq(kit))
    }
    clearTransient(model)
    S[n].start(model, kit)
    return model
  }
  function runInstant(steps) {
    for (const st of steps) {
      if (typeof st === "function") st(true)
      else if (st && st.flash) continue
      else if (st && st.w) {
        const w = model.wires[st.w] || (model.wires[st.w] = {base: "", lit: ""})
        if (st.draw) w.base = "on"
        if (st.lit) w.lit = st.tone || "brand"
      }
    }
  }

  // ---- render: sync the DOM to the model (only changes touch the DOM) -----------------------
  // Text changes roll: the old line lifts out, the new one rises in.
  const swapTo = (el, html) => {
    const spans = el.children
    const on = el.querySelector(".on") || spans[0]
    if (on.innerHTML === html) return
    const off = on === spans[0] ? spans[1] : spans[0]
    off.innerHTML = html
    off.classList.add("pre")
    void off.offsetWidth
    off.classList.remove("pre")
    on.classList.remove("on")
    off.classList.add("on")
    // the retired line leaves the layout once it has faded, so an empty line takes no room
    setTimeout(() => {
      if (!on.classList.contains("on")) on.innerHTML = ""
    }, 450)
  }
  const COLS = {a: "col-a", b: "col-b", c: "col-c"}
  function render() {
    const m = model
    for (const key in els) {
      for (const el of els[key]) {
        if (el.classList.contains("hiw-fx")) el.classList.toggle("is-off", !m.vis.has(key))
        const tone = m.lit.get(key)
        if (el.classList.contains("hiw-port")) el.classList.toggle("is-lit", m.ports.has(key))
        else {
          el.classList.toggle("is-lit", !!tone && tone !== "jolt")
          el.classList.toggle("is-jolt", tone === "jolt")
        }
        if (el.classList.contains("hiw-card")) el.classList.toggle("hiw-q", m.qk.has(key))
        if (el.classList.contains("hiw-row")) {
          el.classList.toggle("r-warn", tone === "warn")
          el.classList.toggle("r-deny", tone === "deny")
        }
        if (el.classList.contains("hiw-card")) el.classList.toggle("is-live", m.live.has(key))
        if (el.hasAttribute("data-gate")) el.classList.toggle("is-gate", m.lit.has("gate"))
        if (key === "term")
          el.classList.toggle("is-journal", !!(m.text.rl0 || "").startsWith("journal"))
        if (key === "runner") el.classList.toggle("has-log", m.vis.has("term"))
        if (el.classList.contains("hiw-dot")) el.classList.toggle("is-on", m.dots.has(key))
        if (el.classList.contains("hiw-swap") && key in m.text) swapTo(el, m.text[key])
      }
    }
    root
      .querySelectorAll(".hiw-port")
      .forEach((p) => p.classList.toggle("is-on", !!p.offsetParent && portVisible(p)))
    if (root.dataset.focus !== m.focus) root.dataset.focus = m.focus
    for (const [tok, key] of Object.entries(COLS))
      all(key).forEach((el) => el.classList.toggle("hiw-q", m.focus.split(" ").includes(tok)))
    all("col-l2").forEach((el) => el.classList.toggle("hiw-q", m.dimW.includes("tls")))
    all("col-l1").forEach((el) => el.classList.toggle("hiw-q", m.dimW.includes("mcp")))
    root.toggleAttribute("data-terse", !!m.terse)
    all("col-b").forEach((el) => el.classList.toggle("is-glow", !!m.glow))
    all("evs").forEach((el) => {
      el.dataset.n = String(["ev1", "ev2", "ev3"].filter((k) => m.vis.has(k)).length)
    })
    for (const w of Object.values(wires)) {
      const dim = m.dimW.includes(w.id)
      w.base.classList.toggle("is-dim", dim)
      w.lit.classList.toggle("is-dim", dim)
      if (w.busy) continue
      const s = m.wires[w.id] || {base: "", lit: ""}
      full(w.base)
      w.base.classList.toggle("is-on", !!s.base)
      w.base.classList.toggle("t-old", s.base === "old")
      if (s.lit) {
        full(w.lit)
        w.lit.classList.remove("t-brand", "t-plain", "t-rose")
        w.lit.classList.add("t-" + s.lit)
      }
      w.lit.classList.toggle("is-on", !!s.lit)
      w.head.classList.remove("is-on")
    }
  }
  // A port shows when the card it sits on is visible and a wire uses it.
  const used = new Set(["ag", "cp-l", "cp-r", "rn", "cp-ap", "you", "sh"])
  function portVisible(p) {
    const name = p.dataset.port
    if (!used.has(name)) return false
    const ids = Object.keys(WIRES).filter((id) => WIRES[id].includes(name))
    if (
      !ids.some((id) => model.wires[id] && model.wires[id].base && model.wires[id].base !== "old")
    )
      return false
    const host = p.parentElement
    return !host.classList.contains("is-off")
  }

  // ---- the clock -----------------------------------------------------------------------------
  let state = 1,
    t = 0,
    dur = 1,
    beats = [],
    anims = [],
    last = 0,
    raf = 0
  // auto: the story advances on its own. frozen: the reader pressed Pause (the clock stops).
  // Like a video player: hovering never pauses; Previous, Next and the tabs jump and keep playing.
  // Keyboard focus arriving from outside pauses until the reader acts (a click or a key).
  let auto = true,
    frozen = false,
    focusIn = false,
    offscreen = true,
    override = false
  const motion = () => !reduce.matches
  const running = () => motion() && !frozen && !offscreen && (override || !focusIn)
  const words = (n) => capSrc[n - 1].textContent.split(/\s+/).filter(Boolean).length
  const reading = (n) => Math.max(3000, READ_MS * words(n)) + (S[n].last || 0)

  function compile(steps) {
    const out = [{at: LEAD, fn: () => {}}]
    let at = LEAD
    for (const st of steps) {
      if (typeof st === "number") {
        at += st
        continue
      }
      if (typeof st === "function") {
        out.push({at, fn: st})
        continue
      }
      if (st.flash) {
        const key = st.flash
        out.push(
          {at, fn: () => model.lit.set(key, "pass")},
          {at: at + 560, fn: () => model.lit.delete(key)}
        )
        continue
      }
      const w = wires[st.w]
      if (!w || !w.L) continue
      const d = Math.min(HOP[1], Math.max(HOP[0], w.L / SPEED))
      out.push({at, travel: st, dur: d})
      if (!st.par) at += d
    }
    return {list: out.sort((a, b) => a.at - b.at), end: at}
  }
  function travel(st, d) {
    const w = wires[st.w]
    const L = w.L
    const tone = st.tone || "brand"
    w.busy = st
    const s0 = model.wires[st.w] || (model.wires[st.w] = {base: "", lit: ""})
    w.head.classList.remove("t-brand", "t-plain", "t-rose")
    w.head.classList.add("t-" + tone, "is-on")
    if (st.lit) {
      w.lit.classList.remove("t-brand", "t-plain", "t-rose")
      w.lit.classList.add("t-" + tone)
    }
    const litAlready = s0.lit === tone
    return {
      tick(p) {
        const s = p * (L + HEAD)
        if (st.rev) span(w.head, L, L - s, L - s + HEAD)
        else span(w.head, L, s - HEAD, s)
        const f = Math.min(L, s)
        if (st.draw) {
          w.base.classList.add("is-on")
          if (st.rev) span(w.base, L, L - f, L)
          else span(w.base, L, 0, f)
        }
        if (st.lit && !litAlready) {
          w.lit.classList.add("is-on")
          if (st.rev) span(w.lit, L, L - f, L)
          else span(w.lit, L, 0, f)
        }
      },
      end() {
        w.busy = null
        if (st.draw) s0.base = "on"
        if (st.lit) s0.lit = tone
        w.head.classList.remove("is-on")
        render()
      }
    }
  }

  function frame(now) {
    raf = 0
    const dt = last ? Math.min(64, now - last) : 16
    last = now
    if (running()) t += dt
    for (const b of beats) {
      if (b.done || b.at > t) continue
      b.done = true
      if (b.fn) {
        b.fn(false)
        render()
      } else if (b.travel)
        anims.push({
          at: b.at,
          dur: b.dur * (1 + HEAD / wires[b.travel.w].L),
          a: travel(b.travel, b.dur)
        })
    }
    for (const a of anims) {
      if (a.done) continue
      const p = Math.min(1, Math.max(0, (t - a.at) / a.dur))
      a.a.tick(p)
      if (p >= 1) {
        a.done = true
        a.a.end()
      }
    }
    paintProgress()
    if (t >= dur && auto && running()) {
      go(state === N ? 1 : state + 1)
      return
    }
    if (running()) kick()
  }
  function kick() {
    if (!raf) {
      last = 0
      raf = requestAnimationFrame(frame)
    }
  }

  function paintProgress() {
    const p = motion() ? Math.min(1, t / dur) : 1
    segs.forEach((s, i) => {
      const n = i + 1
      const fill = s.querySelector("i")
      s.classList.toggle("is-done", n < state)
      fill.style.transform =
        n < state ? "scaleX(1)" : n === state ? "scaleX(" + p.toFixed(4) + ")" : "scaleX(0)"
    })
  }
  function setStepper() {
    acts.forEach((b, i) => {
      if (i === ACT_OF[state]) b.setAttribute("aria-current", "step")
      else b.removeAttribute("aria-current")
    })
    root.dataset.act = String(ACT_OF[state])
    segs.forEach((s, i) => {
      if (i + 1 === state) s.setAttribute("aria-current", "step")
      else s.removeAttribute("aria-current")
    })
  }
  // Each step's caption is server-rendered (it also reserves the tallest caption's height).
  const capHtml = (n) => capSrc[n - 1].innerHTML
  function setCaption(animate) {
    cap.innerHTML = '<span class="hiw-sr">Step ' + state + " of " + N + ". </span>" + capHtml(state)
    countEl.textContent = String(state)
    cap.classList.remove("is-swap")
    if (animate) {
      void cap.offsetWidth
      cap.classList.add("is-swap")
    }
  }

  function go(n, opts = {}) {
    state = n
    t = 0
    anims = []
    beats = []
    root.dataset.s = String(n)
    // The phone layout differs between acts; measure the wires for this act before timing them.
    const act = String(ACT_OF[n])
    if (root.dataset.act !== act) {
      root.dataset.act = act
      layout()
    }
    for (const w of Object.values(wires)) {
      w.busy = null
      w.head.classList.remove("is-on")
    }
    startModel(n)
    const steps = S[n].seq(kit)
    let late = false
    if (opts.settled || !motion()) {
      runInstant(steps)
      dur = 1
      t = 1
    } else {
      const c = compile(steps)
      beats = c.list
      dur = c.end + reading(n)
      late = !opts.init
    }
    if (opts.init) {
      root.classList.add("hiw-init")
      render()
      void root.offsetWidth
      root.classList.remove("hiw-init")
    } else if (!late) render() // in motion the first beat (at LEAD) renders the new start
    setStepper()
    setCaption(!opts.init)
    paintProgress()
    syncPlay()
    kick()
  }
  function syncPlay() {
    const paused = !motion() ? !rmPlaying : !(auto && !frozen)
    playBtn.classList.toggle("is-paused", paused)
    playLabel.textContent = paused ? "Play" : "Pause"
  }

  // Reduced motion: settled frames only; Play steps through them on a timer.
  let rmPlaying = false,
    rmTimer = 0
  function rmStep() {
    clearTimeout(rmTimer)
    if (!rmPlaying) return
    rmTimer = setTimeout(() => {
      if (!rmPlaying) return
      go(state === N ? 1 : state + 1, {settled: true})
      rmStep()
    }, reading(state))
  }

  // ---- input ---------------------------------------------------------------------------------
  const explicit = () => {
    override = true
  }
  // A manual step keeps playing when the player plays; when paused, the step's own motion plays,
  // then it holds until Play.
  const step = (n) => {
    explicit()
    if (!motion()) {
      go(n, {settled: true})
      if (rmPlaying) rmStep()
      return
    }
    if (!(auto && !frozen)) {
      auto = false
      frozen = false
    }
    go(n)
  }
  const prev = () => step(state === 1 ? N : state - 1)
  const next = () => step(state === N ? 1 : state + 1)
  acts.forEach((b, i) => b.addEventListener("click", () => step(ACTS[i])))
  segs.forEach((s, i) => s.addEventListener("click", () => step(i + 1)))
  prevBtn.addEventListener("click", prev)
  nextBtn.addEventListener("click", next)
  playBtn.addEventListener("click", () => {
    explicit()
    if (!motion()) {
      rmPlaying = !rmPlaying
      syncPlay()
      rmStep()
      return
    }
    if (auto && !frozen) {
      auto = false
      frozen = true
      syncPlay()
      paintProgress()
      return
    }
    auto = true
    frozen = false
    if (t >= dur) go(state === N ? 1 : state + 1)
    else {
      syncPlay()
      kick()
    }
  })
  const onKey = (e) => {
    if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return
    if (e.key === "ArrowLeft") {
      e.preventDefault()
      prev()
    } else if (e.key === "ArrowRight") {
      e.preventDefault()
      next()
    }
  }
  root.addEventListener("keydown", onKey)
  const onFocusIn = () => {
    focusIn = true
  }
  const onFocusOut = (e) => {
    if (!root.contains(e.relatedTarget)) {
      focusIn = false
      override = false
      kick()
    }
  }
  root.addEventListener("focusin", onFocusIn)
  root.addEventListener("focusout", onFocusOut)
  let io = null
  if ("IntersectionObserver" in window) {
    io = new IntersectionObserver(
      (es) => {
        offscreen = !es[es.length - 1].isIntersecting
        kick()
      },
      {threshold: 0.2}
    )
    io.observe(root)
  } else offscreen = false
  // The stage and the runner card (which grows when its log opens) move the wires.
  let rz = 0
  const ro = new ResizeObserver(() => {
    cancelAnimationFrame(rz)
    rz = requestAnimationFrame(() => {
      layout()
      render()
    })
  })
  ro.observe(stage)
  all("runner").forEach((el) => ro.observe(el))
  const onReduce = () => {
    rmPlaying = false
    clearTimeout(rmTimer)
    go(state, {settled: !motion()})
  }
  reduce.addEventListener("change", onReduce)

  layout()
  const first = motion() ? 1 : N
  go(first, {init: true, settled: !motion()})
}

export function initHowItWorksMap() {
  document.querySelectorAll("[data-hiw]").forEach(init)
}

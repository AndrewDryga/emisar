// Small browser behaviours that several bundles needed and each had written
// out again. Deliberately framework-free and dependency-free: the marketing
// pages are server-rendered with no LiveSocket, so anything here has to work
// when nothing mounts it as a hook.

// Whether the visitor asked the OS to cut animation. `window.matchMedia` is
// guarded because this runs in the marketing bundle too, which is loaded by
// whatever a search crawler or an old browser brings.
export function reducedMotion() {
  return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)
}

// Runs `fn` the first time `el` is on screen, then stops watching. Without
// IntersectionObserver the behaviour still has to happen, so it runs
// immediately rather than never — these callers animate content that must be
// readable either way.
export function onFirstVisible(el, fn, {threshold = 0.3} = {}) {
  if (!("IntersectionObserver" in window)) {
    fn()
    return () => {}
  }

  const io = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        io.disconnect()
        fn()
      }
    },
    {threshold}
  )
  io.observe(el)
  return () => io.disconnect()
}

// Shows or hides a filtered row by inline `display`, never the `hidden`
// attribute: the rows carry Tailwind `flex`/`grid`/`inline-flex` classes whose
// `display` beats `[hidden]`, so only an inline style reliably hides them.
export function toggleDisplay(el, visible) {
  el.style.display = visible ? "" : "none"
}

// A cancellable set of pending timers, for an animation that has to be able to
// abandon everything it scheduled — a replay, or a tab switch mid-sequence.
export function timers() {
  let pending = []

  return {
    after(ms, fn) {
      pending.push(window.setTimeout(fn, ms))
    },
    clear() {
      pending.forEach((id) => window.clearTimeout(id))
      pending = []
    }
  }
}

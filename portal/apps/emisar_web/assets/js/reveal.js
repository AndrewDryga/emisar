// Restrained on-scroll reveals for the server-rendered marketing site.
//
// Progressive enhancement: the reveal-hiding CSS (`.js-reveal [data-reveal]`)
// only engages once we add `js-reveal` to <html> here, so no-JS visitors and
// crawlers always see every element. Reduced motion (and missing
// IntersectionObserver) reveal everything immediately. Each element reveals
// once, then is unobserved.
export function initReveal() {
  const els = document.querySelectorAll("[data-reveal]")
  if (!els.length) return

  const reduce =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
  const hasIO = "IntersectionObserver" in window

  // Pre-reveal anything already in view, BEFORE engaging the hiding class, so
  // above-the-fold content never flashes hidden. (It also shouldn't animate —
  // the reveal is for scrolling into view; the hero has its own assembly.)
  if (!reduce && hasIO) {
    els.forEach((el) => {
      const r = el.getBoundingClientRect()
      if (r.top < window.innerHeight && r.bottom > 0) el.classList.add("is-in")
    })
  }

  document.documentElement.classList.add("js-reveal")

  if (reduce || !hasIO) {
    els.forEach((el) => el.classList.add("is-in"))
    return
  }

  const io = new IntersectionObserver(
    (entries, obs) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("is-in")
          obs.unobserve(e.target)
        }
      }
    },
    {rootMargin: "0px 0px -8% 0px", threshold: 0.06}
  )
  els.forEach((el) => {
    if (!el.classList.contains("is-in")) io.observe(el)
  })

  // Safety net — never leave content hidden if the observer misbehaves.
  setTimeout(() => els.forEach((el) => el.classList.add("is-in")), 2500)
}

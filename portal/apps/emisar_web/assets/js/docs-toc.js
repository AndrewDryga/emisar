// Scroll-spy for every "On this page" table of contents — the docs shell and
// the legal pages share the `[data-toc-link]` contract and this one active
// mechanism: `data-active` (styled by the `[data-toc-link][data-active]` rule
// in app.css) plus `aria-current`. A no-op anywhere without `[data-toc-link]`.
//
// Plain DOM + IntersectionObserver, no deps, CSP-safe.
export function initTocScrollSpy() {
  const links = Array.from(document.querySelectorAll("[data-toc-link]"))
  if (!links.length) return

  const headings = links
    .map(a => document.getElementById(a.getAttribute("data-toc-link")))
    .filter(Boolean)
  if (!headings.length) return

  const setActive = id => {
    for (const a of links) {
      const on = a.getAttribute("data-toc-link") === id
      if (on) {
        a.setAttribute("data-active", "")
        a.setAttribute("aria-current", "location")
      } else {
        a.removeAttribute("data-active")
        a.removeAttribute("aria-current")
      }
    }
  }

  // The topmost heading intersecting the reading band (below the sticky nav,
  // above the lower third) is the section the reader is on.
  const visible = new Set()
  const observer = new IntersectionObserver(
    entries => {
      for (const e of entries) {
        if (e.isIntersecting) visible.add(e.target.id)
        else visible.delete(e.target.id)
      }
      const active = headings.find(h => visible.has(h.id))
      if (active) setActive(active.id)
    },
    {rootMargin: "-80px 0px -66% 0px", threshold: 0}
  )

  headings.forEach(h => observer.observe(h))
  setActive(headings[0].id)
}

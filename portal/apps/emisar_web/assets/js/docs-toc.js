// Scroll-spy for the docs pages' "On this page" table of contents. A no-op
// anywhere without `[data-toc-link]`. Highlights the TOC entry for the section
// currently near the top of the viewport by toggling `data-active` (styled via
// the `[data-toc-link][data-active]` rule in app.css) and `aria-current`.
//
// Plain DOM + IntersectionObserver, no deps, CSP-safe. The docs shell and the
// legal pages share the `[data-toc-link]` contract but use different active
// mechanisms, so marketing.js runs exactly one of the two per page.
export function initDocsToc() {
  const links = Array.from(document.querySelectorAll("[data-toc-link]"))
  if (!links.length) return

  const byId = new Map(links.map(a => [a.getAttribute("data-toc-link"), a]))
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
      if (active && byId.has(active.id)) setActive(active.id)
    },
    {rootMargin: "-80px 0px -66% 0px", threshold: 0}
  )

  headings.forEach(h => observer.observe(h))
}

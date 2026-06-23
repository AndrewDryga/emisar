// Scroll-spy for the legal pages' "On this page" table of contents. A no-op
// anywhere without `[data-toc-link]`. Highlights the TOC entry whose section is
// currently near the top of the viewport.
//
// Markup contract (the <.legal_page> component in marketing_html.ex):
//   [data-toc-link]=<id>   each TOC anchor; <id> is the section's <h2 id>
export function initLegalToc() {
  const links = Array.from(document.querySelectorAll("[data-toc-link]"))
  if (!links.length) return

  const headings = links
    .map(a => document.getElementById(a.getAttribute("data-toc-link")))
    .filter(Boolean)
  if (!headings.length) return

  const setActive = id => {
    for (const a of links) {
      const on = a.getAttribute("data-toc-link") === id
      a.classList.toggle("border-brand-400", on)
      a.classList.toggle("text-zinc-100", on)
      a.classList.toggle("font-medium", on)
      a.classList.toggle("border-transparent", !on)
      a.classList.toggle("text-zinc-400", !on)
    }
  }

  // A heading counts as "in view" once it crosses into the top 30% of the
  // viewport; the first such heading in document order wins.
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
    {rootMargin: "0px 0px -70% 0px", threshold: 0}
  )

  headings.forEach(h => observer.observe(h))
  setActive(headings[0].id)
}

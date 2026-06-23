// Client-side filter for the /packs registry. A no-op on every page that
// doesn't render the search box (`#pack-search`). Pure DOM — the marketing
// bundle has no LiveView/socket, so this is a few hundred bytes of vanilla JS.
//
// Markup contract (packs.html.heex):
//   #pack-search                  the search input
//   [data-pack-section] / id=slug each category block (also the anchor target)
//   [data-pack-name]              each pack card; attr = "name id", lowercased
//   [data-pack-count]             the count span in a category heading
//   [data-pack-nav]               a jump-nav pill; attr = the category slug
//   #pack-search-empty            the "no matches" message
export function initPackSearch() {
  const input = document.getElementById("pack-search")
  if (!input) return

  const sections = Array.from(document.querySelectorAll("[data-pack-section]"))
  const navItems = Array.from(document.querySelectorAll("[data-pack-nav]"))
  const empty = document.getElementById("pack-search-empty")

  // Pre-fill from ?q= so a filtered view is shareable (and testable).
  const initial = new URLSearchParams(window.location.search).get("q")
  if (initial) input.value = initial

  // Toggle inline `display`, not the `hidden` attribute: the cards/pills carry
  // Tailwind `flex`/`inline-flex` classes whose `display` beats `[hidden]`, so
  // only an inline style reliably hides them.
  const show = (el, on) => {
    el.style.display = on ? "" : "none"
  }

  const apply = () => {
    const q = input.value.trim().toLowerCase()
    let anyVisible = false

    for (const section of sections) {
      let shown = 0
      for (const card of section.querySelectorAll("[data-pack-name]")) {
        const match = !q || card.getAttribute("data-pack-name").includes(q)
        show(card, match)
        if (match) shown++
      }
      show(section, shown > 0)
      if (shown > 0) anyVisible = true

      const count = section.querySelector("[data-pack-count]")
      if (count) count.textContent = q ? String(shown) : count.dataset.packCount
    }

    for (const nav of navItems) {
      const section = document.getElementById(nav.getAttribute("data-pack-nav"))
      show(nav, !section || section.style.display !== "none")
    }

    if (empty) empty.style.display = anyVisible ? "none" : "block"
  }

  input.addEventListener("input", apply)
  apply()
}

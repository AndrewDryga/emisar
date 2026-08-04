// Client-side filter for the /docs index. A no-op on every page that doesn't
// render the input (`#docs-filter`). Pure DOM — the marketing bundle has no
// LiveView/socket, and the whole tree is already server-rendered, so this only
// hides rows a crawler and a no-JS visitor still get in full.
//
// It matches the metadata the server put on each row (title, description,
// group, subgroup, DocsNav keywords) — not page bodies — which is what the
// input's label promises. No query-param prefill: unlike a pack search, a
// filtered index is a way to reach a page, not a view worth sharing.
//
// Markup contract (docs.html.heex):
//   #docs-filter          the filter input
//   [data-docs-group]     a top-level group block; attr = the group label
//   [data-docs-subgroup]  a section inside a group (labelled or not)
//   [data-docs-page]      a page row; attr = its lowercased search terms
//   #docs-filter-empty    the "no matches" message
export function initDocsFilter() {
  const input = document.getElementById("docs-filter")
  if (!input) return

  const groups = Array.from(document.querySelectorAll("[data-docs-group]"))
  const empty = document.getElementById("docs-filter-empty")

  // Toggle inline `display`, not the `hidden` attribute: the rows carry
  // Tailwind `flex`/`grid` classes whose `display` beats `[hidden]`, so only
  // an inline style reliably hides them.
  const show = (el, on) => {
    el.style.display = on ? "" : "none"
  }

  const apply = () => {
    const q = input.value.trim().toLowerCase()
    let anyVisible = false

    for (const group of groups) {
      let groupShown = 0

      for (const section of group.querySelectorAll("[data-docs-subgroup]")) {
        let shown = 0
        for (const row of section.querySelectorAll("[data-docs-page]")) {
          const match = !q || row.getAttribute("data-docs-page").includes(q)
          show(row, match)
          if (match) shown++
        }
        show(section, shown > 0)
        groupShown += shown
      }

      show(group, groupShown > 0)
      if (groupShown > 0) anyVisible = true
    }

    if (empty) empty.style.display = anyVisible ? "none" : "block"
  }

  input.addEventListener("input", apply)
  apply()
}

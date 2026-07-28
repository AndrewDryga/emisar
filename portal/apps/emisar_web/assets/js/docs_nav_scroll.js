// Brings the current page's entry into view in the docs sidebar on load. A
// no-op anywhere without `nav[aria-label="Docs"]`.
//
// The rail is a sticky `overflow-y-auto` container capped at `calc(100vh-4rem)`,
// and the nav has grown long enough (Operate plus the five Integrations guides)
// that on a short viewport the active entry sits hundreds of pixels below the
// fold — /docs/integrations/okta puts it at 943px inside a 636px rail. The
// reader arrives with the tree scrolled to the top and no indication of where
// in it they are.
//
// Sets `scrollTop` arithmetically rather than calling `scrollIntoView()`, which
// walks every scrollable ancestor including the document: that would scroll the
// window too, dropping the reader below the title of the page they just opened.
// Instant, not smooth — this is placement before first paint, not a transition
// anyone should watch.
export function initDocsNavScroll() {
  const nav = document.querySelector('nav[aria-label="Docs"]')
  if (!nav) return

  const active = nav.querySelector('[aria-current="page"]')
  if (!active) return

  // Nothing to do when the whole tree already fits.
  if (nav.scrollHeight <= nav.clientHeight) return

  const navBox = nav.getBoundingClientRect()
  const activeBox = active.getBoundingClientRect()
  if (activeBox.top >= navBox.top && activeBox.bottom <= navBox.bottom) return

  // Centre the entry so the neighbours above and below stay visible as context —
  // knowing Okta sits under Integrations, between Keycloak and the next guide,
  // is most of the value. Clamped to the scroll range so an entry near either
  // end settles flush instead of leaving dead space.
  const offsetInContent = activeBox.top - navBox.top + nav.scrollTop
  const centred = offsetInContent - (nav.clientHeight - activeBox.height) / 2
  nav.scrollTop = Math.max(0, Math.min(centred, nav.scrollHeight - nav.clientHeight))
}

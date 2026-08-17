// Shared geometry for the absolutely-positioned overlays — the <.tooltip>
// bubble and the <.dropdown> panel. Both anchor to a trigger that can sit
// anywhere on the page, and both must land inside the visible work canvas:
// `main` clips horizontally (`overflow-x: clip`), and past the window edge
// there is nothing to see. One helper so the two can never drift apart.

// Breathing room between an overlay and the edge it was pulled back from.
const INSET = 8

// The console's work canvas, intersected with the window. A trigger outside
// `main` — the sidebar's workspace switcher — is bounded by the window alone.
export function canvasBounds(el) {
  const canvas = el.closest("main")?.getBoundingClientRect()
  return {
    left: Math.max(INSET, (canvas?.left ?? 0) + INSET),
    right: Math.min(window.innerWidth - INSET, (canvas?.right ?? window.innerWidth) - INSET)
  }
}

// How far `rect` must slide horizontally to sit inside those bounds — 0 when it
// already does. An overlay wider than the canvas keeps its left edge visible,
// because that is where its content starts.
export function horizontalShift(el, rect) {
  const {left, right} = canvasBounds(el)
  if (rect.left < left) return left - rect.left
  if (rect.right > right) return Math.max(right - rect.right, left - rect.left)
  return 0
}

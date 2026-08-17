// Shared geometry for the absolutely-positioned overlays — the <.tooltip>
// bubble, the <.dropdown> panel, and the <.searchable_select> panel. All three
// anchor to a trigger that can sit anywhere on the page, and all three must land
// inside the visible work canvas: `main` clips horizontally (`overflow-x: clip`),
// and past the window edge there is nothing to see. One helper so they cannot
// drift apart — and so a fourth overlay inherits the behaviour by calling it.

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

// Which side of the trigger the overlay ends up on, and how far it must move to
// get there — 0 while the side its own CSS put it on still fits. The vertical
// bound is the window: the console's page title scrolls with the content, so
// there is no fixed chrome to stay clear of.
function verticalShift(trigger, rect, side) {
  // The gap the call site asked for, read back rather than assumed — `mt-2` on
  // one menu, `mb-2` under a tooltip, none at all on a fused select panel.
  const gap = side === "above" ? trigger.top - rect.bottom : rect.top - trigger.bottom
  const above = trigger.top - gap - rect.height - INSET
  const below = window.innerHeight - INSET - (trigger.bottom + gap + rect.height)
  const [room, otherRoom] = side === "above" ? [above, below] : [below, above]

  // Flip only when the declared side genuinely overflows AND the other one is
  // roomier. On a screen too short for the overlay either way, flipping would
  // hide MORE of it than leaving it where the call site put it.
  if (room >= 0 || otherRoom <= room) return {side, y: 0}

  return side === "above"
    ? {side: "below", y: trigger.bottom + gap - rect.top}
    : {side: "above", y: trigger.top - gap - rect.bottom}
}

// Opens `overlay` on the side of `trigger` that fits and slides it back inside
// the canvas. Every offset is measured from real rects and applied as one
// transform, so a call site's own gap and `align` anchor keep working untouched.
//
// `side` is where the markup declared it — the caller's constant, never read
// back off the element, which this rewrites. The side it ENDS on is both
// returned and stamped as `data-side`, so the chrome that follows a flip (a
// tooltip's hover bridge, a select panel's fused border) is one CSS variant
// instead of a second copy of the decision.
export function positionOverlay(root, trigger, overlay, side) {
  overlay.style.transform = ""

  // `panel_position={:flow_on_narrow}` leaves a dropdown panel in document flow
  // below xl. In flow it pushes its siblings down instead of overlaying them, so
  // there is no overflow to pull back — and moving it would tear it off the
  // space the layout already reserved.
  if (getComputedStyle(overlay).position !== "absolute") return side

  const rect = overlay.getBoundingClientRect()
  // A hidden overlay measures as a zero rect, which nothing can be decided from.
  // Whatever reveals it positions it again.
  if (!rect.width && !rect.height) return side

  const vertical = verticalShift(trigger.getBoundingClientRect(), rect, side)
  const x = horizontalShift(root, rect)

  overlay.style.transform = x || vertical.y ? `translate(${x}px, ${vertical.y}px)` : ""
  overlay.dataset.side = vertical.side
  return vertical.side
}

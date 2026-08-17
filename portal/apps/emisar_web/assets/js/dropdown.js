// Positioning for the shared <.dropdown>, used by BOTH bundles. The panel is a
// plain absolutely-positioned box under a native <details>, so it always opened
// downward and rightward from wherever the trigger happened to sit: on the last
// row of a long list it ran past the bottom of the screen, and on a phone — where
// a row's actions take their own full-width line — a right-aligned panel ran off
// the LEFT of the canvas, which `main` clips away entirely.
//
// This slides the panel back in: above the trigger when there is no room below,
// and inward from the canvas edge, sharing the tooltip's clamp. Every offset is
// measured from real rects and applied as a transform, so a call site's own
// `mt-*` gap and `align` anchor keep working untouched.
import {horizontalShift} from "./overlay.js"

// Matches the canvas inset the horizontal clamp uses, so a panel pulled back
// from either edge keeps the same breathing room.
const INSET = 8

export function positionDropdown(details) {
  const panel = details.querySelector("[data-dropdown-panel]")
  const summary = details.querySelector("summary")
  if (!panel || !summary) return

  panel.style.transform = ""
  // `panel_position={:flow_on_narrow}` leaves the panel in document flow below
  // xl. In flow it pushes its siblings down instead of overlaying them, so
  // there is no overflow to pull back — and moving it would tear it off the
  // space the layout already reserved.
  if (getComputedStyle(panel).position !== "absolute") return

  const trigger = summary.getBoundingClientRect()
  const rect = panel.getBoundingClientRect()
  // The gap the call site asked for, read back rather than assumed — `mt-2` on
  // one menu, `mt-1` on the workspace switcher.
  const gap = rect.top - trigger.bottom
  const roomBelow = window.innerHeight - INSET - rect.bottom
  const roomAbove = trigger.top - gap - rect.height - INSET
  // Flip only when above is genuinely roomier. On a screen too short for the
  // panel either way, flipping would hide MORE of it than leaving it below.
  const flipped = roomBelow < 0 && roomAbove > roomBelow
  const y = flipped ? trigger.top - gap - rect.bottom : 0
  const x = horizontalShift(details, rect)

  panel.style.transform = x || y ? `translate(${x}px, ${y}px)` : ""
}

function openDropdowns() {
  return document.querySelectorAll("[data-dropdown][open]")
}

// One delegated listener per document covers every dropdown — those a LiveView
// patch adds later included — with no per-element id and no hook, which is why
// the console and the static pages wire it the same way. `toggle` does not
// bubble, so it is caught in the CAPTURE phase; `scroll` is captured for the
// same reason, since a scroll inside any container changes how much room is
// left below an open panel.
export function initDropdowns() {
  document.addEventListener(
    "toggle",
    (event) => {
      const details = event.target
      if (details instanceof Element && details.matches("[data-dropdown]") && details.open) {
        positionDropdown(details)
      }
    },
    true
  )

  const reposition = () => {
    const open = openDropdowns()
    if (open.length) open.forEach((details) => positionDropdown(details))
  }

  window.addEventListener("resize", reposition)
  window.addEventListener("scroll", reposition, true)
}

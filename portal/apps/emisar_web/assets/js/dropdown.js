// Positioning for the shared <.dropdown>, used by BOTH bundles. The panel is a
// plain absolutely-positioned box under a native <details>, so it always opened
// downward and rightward from wherever the trigger happened to sit: on the last
// row of a long list it ran past the bottom of the screen, and on a phone — where
// a row's actions take their own full-width line — a right-aligned panel ran off
// the LEFT of the canvas, which `main` clips away entirely.
//
// The geometry that pulls it back — the flip and the canvas clamp — is shared
// with the tooltip bubble and the select panel in overlay.js.
import {positionOverlay} from "./overlay.js"

export function positionDropdown(details) {
  const panel = details.querySelector("[data-dropdown-panel]")
  const summary = details.querySelector("summary")
  if (!panel || !summary) return

  // Every call site hangs its panel below the trigger — `top-full` on the
  // stretched workspace switcher, a plain `mt-*` offset on the row menus.
  positionOverlay(details, summary, panel, "below")
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

// Behaviour for the shared <.tooltip>, used by BOTH bundles: the console mounts
// it as a LiveView hook, and the server-rendered marketing pages (a pack's risk
// pills) wire it once on load. CSS owns the reveal; this adds WCAG 1.4.13
// "Dismissable" (Escape) plus horizontal viewport clamping, which keeps a long
// bubble inside the visible work canvas when its trigger sits near an edge —
// the same clamp the dropdown panel uses, shared through overlay.js.
import {horizontalShift} from "./overlay.js"

export function wireTooltip(el) {
  const bubble = el?.querySelector("[data-tooltip-bubble]")
  if (!bubble) return () => {}

  const onKey = (e) => { if (e.key === "Escape") bubble.classList.add("hidden") }

  const position = () => {
    bubble.style.transform = ""
    bubble.style.transform = `translateX(${horizontalShift(el, bubble.getBoundingClientRect())}px)`
  }

  const rearm = () => {
    bubble.classList.remove("hidden")
    requestAnimationFrame(position)
  }

  // The bubble is an overlay: a click inside it acts on the BUBBLE's content,
  // never on whatever row/link the trigger happens to sit in. Defaults inside
  // the bubble (a link, the Copy button's own handler) still run.
  const shield = (e) => e.stopPropagation()

  el.addEventListener("keydown", onKey)
  el.addEventListener("mouseenter", rearm)
  el.addEventListener("focusin", rearm)
  bubble.addEventListener("click", shield)
  window.addEventListener("resize", position)

  return () => {
    el.removeEventListener("keydown", onKey)
    el.removeEventListener("mouseenter", rearm)
    el.removeEventListener("focusin", rearm)
    bubble.removeEventListener("click", shield)
    window.removeEventListener("resize", position)
  }
}

export const Tooltip = {
  mounted() { this.unwire = wireTooltip(this.el) },
  destroyed() { this.unwire?.() }
}

// A static page has no LiveView, so nothing mounts the hook and its DOM never
// changes — one pass over the rendered bubbles at load is the whole job.
export function initTooltips() {
  document
    .querySelectorAll("[data-tooltip-bubble]")
    .forEach((bubble) => wireTooltip(bubble.parentElement))
}

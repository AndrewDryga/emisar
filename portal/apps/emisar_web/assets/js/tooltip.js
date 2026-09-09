// Behaviour for the shared <.tooltip>, used by BOTH bundles: the console mounts
// it as a LiveView hook, and the server-rendered marketing pages (a pack's risk
// pills) wire it once on load. CSS owns the reveal; this adds WCAG 1.4.13
// "Dismissable" (Escape) plus the shared overlay geometry — the bubble opens on
// whichever side of its trigger has room and stays inside the visible work
// canvas, the same routine the dropdown and select panels position against.
import {positionOverlay} from "./overlay.js"

export function wireTooltip(el) {
  const bubble = el?.querySelector("[data-tooltip-bubble]")
  if (!bubble) return () => {}

  // The side `placement` declared. positionOverlay rewrites `data-side` the
  // first time it has to flip, so read the declaration once, before it can.
  const placement = bubble.dataset.side

  const onKey = (e) => { if (e.key === "Escape") bubble.classList.add("hidden") }

  // The wrapper IS the trigger box — the bubble inside it is absolutely
  // positioned, so it never grows that rect.
  const position = () => positionOverlay(el, el, bubble, placement)

  // Watched only while the tip is up: revealed, it has to follow a resize or a
  // scroll that changes which side fits (a focused trigger keeps its tip up
  // while the page scrolls under it); hidden, the next reveal measures it
  // anyway, so a page of tooltips holds no idle listeners.
  const watch = () => {
    window.addEventListener("resize", position)
    window.addEventListener("scroll", position, true)
  }

  const unwatch = () => {
    window.removeEventListener("resize", position)
    window.removeEventListener("scroll", position, true)
  }

  const rearm = () => {
    bubble.classList.remove("hidden")
    watch()
    requestAnimationFrame(position)
  }

  const leave = (event) => {
    const focused = event.type === "focusout" ? el.contains(event.relatedTarget) : el.contains(document.activeElement)
    if (!el.matches(":hover") && !focused) {
      unwatch()
    }
  }

  // The bubble is an overlay: a click inside it acts on the BUBBLE's content,
  // never on whatever row/link the trigger happens to sit in. Explicit LiveView
  // controls need to reach its delegated window listener; that listener picks
  // the inner control instead of an enclosing row. Plain content stays shielded.
  // Native links and Copy's capture-phase handler still work as before.
  const shield = (e) => {
    const control = e.target.closest("[phx-click], [data-phx-link]")
    if (!control || !bubble.contains(control)) e.stopPropagation()
  }

  el.addEventListener("keydown", onKey)
  el.addEventListener("mouseenter", rearm)
  el.addEventListener("focusin", rearm)
  el.addEventListener("mouseleave", leave)
  el.addEventListener("focusout", leave)
  bubble.addEventListener("click", shield)

  return () => {
    el.removeEventListener("keydown", onKey)
    el.removeEventListener("mouseenter", rearm)
    el.removeEventListener("focusin", rearm)
    el.removeEventListener("mouseleave", leave)
    el.removeEventListener("focusout", leave)
    bubble.removeEventListener("click", shield)
    unwatch()
  }
}

export const Tooltip = {
  mounted() {
    this.unwire = wireTooltip(this.el)
  },
  updated() {
    const bubble = this.el.querySelector("[data-tooltip-bubble]")
    if (bubble && this.el.matches(":hover, :focus-within")) {
      requestAnimationFrame(() => positionOverlay(this.el, this.el, bubble, bubble.dataset.side))
    }
  },
  destroyed() {
    this.unwire?.()
  }
}

// A static page has no LiveView, so nothing mounts the hook and its DOM never
// changes — one pass over the rendered bubbles at load is the whole job.
export function initTooltips() {
  document
    .querySelectorAll("[data-tooltip-bubble]")
    .forEach((bubble) => wireTooltip(bubble.parentElement))
}

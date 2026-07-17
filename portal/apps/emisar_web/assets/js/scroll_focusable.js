// Keyboard access for scrollable regions on the static marketing site
// (WCAG 2.1.1 / axe `scrollable-region-focusable`). A <pre> code block, an
// overflow-x table wrapper, or the demo terminal can clip content that a
// keyboard-only visitor then can't reach: a scroll container needs a tab stop
// so it can take focus and be arrow-scrolled (the global focus-visible ring
// shows it).
//
// Only a region that ACTUALLY overflows and has NO focusable child of its own
// needs the tab stop — and both are knowable only at render time — so this runs
// client-side on load and re-checks on resize. Marketing pages are static HTML
// (no LiveView patching), so that's enough; the console renders its scroll
// regions focusable server-side (LiveTable, code_panel) where morphdom would
// otherwise strip a JS-set attribute.
const CANDIDATE =
  "pre, [class*='overflow-x-auto'], [class*='overflow-y-auto'], [class*='overflow-auto']";
const FOCUSABLE_CHILD = "a[href], button, input, select, textarea, [tabindex]";

function refresh() {
  document.querySelectorAll(CANDIDATE).forEach((el) => {
    const overflows =
      el.scrollWidth > el.clientWidth + 1 ||
      el.scrollHeight > el.clientHeight + 1;
    // A region that contains its own focusable element is already reachable —
    // adding a tab stop there just double-stops the keyboard (axe exempts it).
    const reachable = el.querySelector(FOCUSABLE_CHILD) !== null;
    if (overflows && !reachable && !el.hasAttribute("tabindex")) {
      el.setAttribute("tabindex", "0");
      el.dataset.scrollFocusable = "1";
    } else if (el.dataset.scrollFocusable === "1" && (!overflows || reachable)) {
      // A resize made it fit (or a focusable child appeared) — drop the tab stop
      // we added, so a region that no longer scrolls isn't a dead focus target.
      el.removeAttribute("tabindex");
      delete el.dataset.scrollFocusable;
    }
  });
}

export function initScrollFocusable() {
  refresh();
  let pending;
  window.addEventListener("resize", () => {
    clearTimeout(pending);
    pending = setTimeout(refresh, 150);
  });
}

// Marketing pricing page — monthly/annual price toggle.
//
// The marketing bundle ships NO LiveSocket (see marketing.js), so this can't
// be a `phx-click`. Same plain-JS class-toggle idiom as mobile_nav.js: flip the
// `hidden` class on the per-cycle price blocks and repaint the segmented
// buttons. No-ops when the toggle markup is absent (every non-pricing page).
//
// Only the Team card carries a paid annual price; Free ($0) and Enterprise
// (Custom) have no `[data-cycle-price]` blocks, so they never change.
export function initPricingCycle() {
  const toggle = document.querySelector("[data-cycle-toggle]")
  if (!toggle) return

  const buttons = toggle.querySelectorAll("[data-cycle]")
  const prices = document.querySelectorAll("[data-cycle-price]")

  const apply = (cycle) => {
    prices.forEach((el) => el.classList.toggle("hidden", el.dataset.cyclePrice !== cycle))
    buttons.forEach((btn) => {
      const active = btn.dataset.cycle === cycle
      btn.setAttribute("aria-pressed", active ? "true" : "false")
      btn.classList.toggle("bg-zinc-800", active)
      btn.classList.toggle("text-zinc-100", active)
      btn.classList.toggle("text-zinc-400", !active)
    })
  }

  buttons.forEach((btn) => btn.addEventListener("click", () => apply(btn.dataset.cycle)))
}

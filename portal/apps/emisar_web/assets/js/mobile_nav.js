// Marketing mobile nav — a plain-JS drawer toggle with a focus trap.
//
// The marketing bundle deliberately ships NO LiveSocket, so the drawer cannot
// use `phx-click={JS.show(...)}` commands (they're inert without the LV client,
// which left the hamburger — and the only mobile "Sign in" — dead). This opens
// it with a class toggle, mirroring pack_search.js. No-ops when the markup is
// absent.
//
// The panel is an `aria-modal` dialog, so it also traps Tab within the drawer,
// moves focus inside on open, and restores it to the trigger on close — without
// that, a keyboard/SR user tabs straight into the page hidden behind the
// backdrop.
export function initMobileNav() {
  const panel = document.getElementById("marketing-mobile-nav")
  const openBtn = document.querySelector("[data-mobile-nav-open]")
  if (!panel || !openBtn) return

  const focusable = () => panel.querySelectorAll("a[href], button:not([disabled])")
  const isOpen = () => !panel.classList.contains("hidden")

  const open = () => {
    panel.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    openBtn.setAttribute("aria-expanded", "true")
    focusable()[0]?.focus()
  }
  const close = () => {
    panel.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    openBtn.setAttribute("aria-expanded", "false")
    openBtn.focus()
  }

  openBtn.addEventListener("click", open)
  panel.querySelectorAll("[data-mobile-nav-close]").forEach((el) => el.addEventListener("click", close))
  // A nav tap triggers a full page load, but close first so the body lock
  // never persists across the navigation.
  panel.querySelectorAll("a[href]").forEach((a) => a.addEventListener("click", close))

  document.addEventListener("keydown", (e) => {
    if (!isOpen()) return
    if (e.key === "Escape") return close()
    if (e.key !== "Tab") return

    const items = focusable()
    if (items.length === 0) return
    const first = items[0]
    const last = items[items.length - 1]
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault()
      first.focus()
    }
  })
}

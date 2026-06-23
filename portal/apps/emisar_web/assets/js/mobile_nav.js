// Marketing mobile nav — a plain-JS drawer toggle.
//
// The marketing bundle deliberately ships NO LiveSocket, so the drawer cannot
// use `phx-click={JS.show(...)}` commands (they're inert without the LV client,
// which left the hamburger — and the only mobile "Sign in" — dead). This opens
// it with a class toggle, mirroring pack_search.js. No-ops when the markup is
// absent.
export function initMobileNav() {
  const panel = document.getElementById("marketing-mobile-nav")
  const openBtn = document.querySelector("[data-mobile-nav-open]")
  if (!panel || !openBtn) return

  const open = () => {
    panel.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    openBtn.setAttribute("aria-expanded", "true")
  }
  const close = () => {
    panel.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    openBtn.setAttribute("aria-expanded", "false")
  }

  openBtn.addEventListener("click", open)
  panel.querySelectorAll("[data-mobile-nav-close]").forEach((el) => el.addEventListener("click", close))
  // A nav tap triggers a full page load, but close first so the body lock
  // never persists across the navigation.
  panel.querySelectorAll("a[href]").forEach((a) => a.addEventListener("click", close))
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !panel.classList.contains("hidden")) close()
  })
}

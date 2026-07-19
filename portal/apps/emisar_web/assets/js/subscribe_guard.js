// Single-submit guard for the marketing subscribe form(s) (`[data-subscribe]`).
//
// The form is a plain server POST that redirects on success, so the multi-send
// vector is a double-click (or an impatient re-click) in the in-flight window
// before the browser navigates. On submit we disable the button and lock the
// input, so a second click can't fire the POST again; the fresh page after the
// redirect resets it. The backend also dedupes by email (upsert), so a repeat
// is harmless — this is UX, not the integrity guard.
//
// CSP-safe: one delegated `submit` listener, no inline handler. A no-op on any
// page without a `[data-subscribe]` form.
export function initSubscribeGuard() {
  document.addEventListener("submit", (e) => {
    const form = e.target
    if (!(form instanceof HTMLFormElement) || !form.matches("[data-subscribe]")) {
      return
    }

    // The submission is already in flight by the time this fires, so disabling
    // the button here can't cancel it — it only blocks a second dispatch.
    const button = form.querySelector('button[type="submit"]')
    if (button && !button.disabled) {
      button.disabled = true
      button.classList.add("cursor-not-allowed", "opacity-70")
      button.textContent = "Subscribing…"
    }

    // readOnly (not disabled) so the email still serializes into the POST.
    const email = form.querySelector('input[type="email"]')
    if (email) email.readOnly = true
  })
}

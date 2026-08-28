// Fullscreen viewer for `<.docs_screenshot>` figures — plain JS, because the
// docs pages are controller-rendered and ship no LiveSocket (mirrors
// mobile_nav.js). Each figure's Expand button opens its own overlay dialog;
// Escape, the close button, or a click anywhere (the overlay is one big
// cursor-zoom-out target) closes it and returns focus to the figure's button.
// The close button is the dialog's only focusable control, so Tab is contained
// by parking focus on it. No-ops on pages without screenshots.
//
// Deliberately NOT unified with mobile_nav.js's dialog: the two keyboard
// contracts differ where it matters — this parks Tab on one control, the
// drawer cycles focus across many — so a shared helper would grow a config
// knob per difference, and each file now reads as its complete keyboard
// contract.
export function initDocsLightbox() {
  const dialogs = Array.from(document.querySelectorAll("[data-lightbox]"))
  if (dialogs.length === 0) return

  let opener = null
  const openDialog = () => dialogs.find((d) => !d.classList.contains("hidden"))

  const open = (btn, dialog) => {
    opener = btn
    dialog.classList.remove("hidden")
    dialog.classList.add("flex")
    document.body.classList.add("overflow-hidden")
    dialog.querySelector("[data-lightbox-close]")?.focus()
  }
  const close = (dialog) => {
    dialog.classList.add("hidden")
    dialog.classList.remove("flex")
    document.body.classList.remove("overflow-hidden")
    if (opener && opener.isConnected) opener.focus()
    opener = null
  }

  document.querySelectorAll("[data-lightbox-open]").forEach((btn) => {
    const dialog = document.getElementById(btn.dataset.lightboxOpen)
    if (!dialog) return
    btn.addEventListener("click", () => open(btn, dialog))
  })

  // Anywhere on the overlay closes — the close button's own click also bubbles
  // here, which is the same close.
  dialogs.forEach((dialog) => dialog.addEventListener("click", () => close(dialog)))

  document.addEventListener("keydown", (e) => {
    const dialog = openDialog()
    if (!dialog) return
    if (e.key === "Escape") return close(dialog)
    if (e.key === "Tab") {
      e.preventDefault()
      dialog.querySelector("[data-lightbox-close]")?.focus()
    }
  })
}

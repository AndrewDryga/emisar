// Install-instruction OS switch — the segmented control that picks a
// command's per-OS spelling (Linux / Windows / macOS).
//
// The SERVER picks the default from the request's User-Agent
// (EmisarWeb.UserAgent.platform/1), so a Windows visitor lands on the
// PowerShell command with no flash and a crawler sees both. This module owns
// only the click: same delegated, plain-JS idiom as copy.js, because it has to
// work identically on the console (LiveSocket) and on the static docs pages
// (no LiveSocket, so no phx-click and no hook).
//
// The choice applies PAGE-WIDE, not per block: a page with an install and a
// rollback snippet would otherwise strand the reader mid-page on the other
// platform. Markup contract, matching the component:
//
//   <button data-os-select="windows">  the tab
//   <element data-os="windows">        shown only while that OS is selected
//
// A LiveView re-render repaints the server's default, which is the detected
// OS — the honest thing to snap back to.
const ACTIVE = ["bg-zinc-800", "text-zinc-100"]
const INACTIVE = ["text-zinc-400"]

function selectOs(os) {
  document.querySelectorAll("[data-os]").forEach((el) => {
    el.classList.toggle("hidden", el.dataset.os !== os)
  })
  document.querySelectorAll("[data-os-select]").forEach((btn) => {
    const active = btn.dataset.osSelect === os
    btn.setAttribute("aria-pressed", active ? "true" : "false")
    ACTIVE.forEach((c) => btn.classList.toggle(c, active))
    INACTIVE.forEach((c) => btn.classList.toggle(c, !active))
  })
}

export function initOsTabs() {
  document.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-os-select]")
    if (!btn) return
    e.preventDefault()
    selectOs(btn.dataset.osSelect)
  })
}

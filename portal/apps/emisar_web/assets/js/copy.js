// Clipboard copy via a delegated document-level click listener rather
// than a Phoenix hook, for two reasons:
//
//   1. CSP forbids inline `onclick` handlers — historically every Copy
//      button broke silently because the inline handler was stripped by
//      the CSP middleware in prod.
//   2. The CSP-safe alternative (`phx-hook`) only attaches to elements
//      inside a LiveView container. The marketing site (controller-
//      rendered: pack detail, install snippets, …) has no LiveSocket, so
//      a hook there is dead.
//
// This listener is the one piece of clipboard code shared by both JS
// bundles — `app.js` (the authenticated console) and `marketing.js` (the
// static site) — so Copy works everywhere without either bundle pulling
// in the other's weight.
//
// The button just needs `data-copy="#some-id"` (id of the element whose
// textContent to grab) OR `data-copy-text="literal string"`. Optional
// `data-copy-label-copied="Copied!"` overrides the flash label;
// otherwise it flips to "Copied" for 1.5s.
export function setupCopyToClipboardDelegation() {
  async function tryWriteToClipboard(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text)
        return true
      }
    } catch (_e) { /* fall through */ }

    // Fallback for non-secure contexts (dev over plain http, some
    // embedded webviews). Off-screen textarea + execCommand("copy").
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.top = "-1000px"
    document.body.appendChild(ta)
    ta.select()
    let ok = false
    try { ok = document.execCommand("copy") } catch (_e) {}
    document.body.removeChild(ta)
    return ok
  }

  function resolveText(btn) {
    if (btn.dataset.copyText != null) return btn.dataset.copyText
    const sel = btn.dataset.copy
    if (!sel) return null
    const target = document.querySelector(sel)
    if (!target) return null
    // Strip the first content line's indentation (HEEx template
    // whitespace) and the same prefix from later lines, so a multi-line
    // snippet copies without the template's leading indentation, then
    // drop trailing whitespace. This CANNOT tell template indent from an
    // intentional leading space, so leading-whitespace-significant
    // content (e.g. a ` curl …` command relying on
    // HISTCONTROL=ignorespace to skip shell history) must be copied via
    // `data-copy-text` (the literal-string path above), not a selector.
    const raw = target.innerText
    const lines = raw.replace(/\s+$/, "").split("\n")
    while (lines.length && lines[0].trim() === "") lines.shift()
    if (!lines.length) return ""
    // Strip the indentation of the first content line, then apply the
    // same strip to every subsequent line (so a multi-line snippet
    // keeps its relative indentation).
    const indent = lines[0].match(/^[ \t]*/)[0]
    return lines.map(l => l.startsWith(indent) ? l.slice(indent.length) : l).join("\n")
  }

  function flashCopied(btn) {
    // Save/restore innerHTML, not innerText: a button whose content is an
    // icon (an inline <.copyable_id> clipboard, or the "＋ icon + label"
    // copy buttons) has empty innerText, so the innerText round-trip would
    // wipe the icon permanently after the first copy. textContent for the
    // flash keeps the label a plain string (no markup injection).
    const original = btn.innerHTML
    btn.textContent = btn.dataset.copyLabelCopied || "Copied"
    if (btn._copyTimer) clearTimeout(btn._copyTimer)
    btn._copyTimer = setTimeout(() => { btn.innerHTML = original }, 1500)
  }

  document.addEventListener("click", async (e) => {
    // Closest so clicks on a nested icon/span inside the button still fire.
    const btn = e.target.closest("[data-copy], [data-copy-text]")
    if (!btn) return
    e.preventDefault()
    const text = resolveText(btn)
    if (text == null || text === "") return
    if (await tryWriteToClipboard(text)) flashCopied(btn)
  })
}

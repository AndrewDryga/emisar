// Lean JS bundle for the server-rendered marketing site
// (`controllers/marketing_html/*`). Those pages are static and have NO
// LiveView socket, so they must NOT pull in `phoenix_live_view` / the
// LiveSocket / hooks / topbar — that's ~50 KiB of JS the crawler and
// every visitor would download and never use.
//
// Marketing needs a small set of local interactions:
//   * copy-to-clipboard buttons (install snippets, pack detail) — shared
//     with the app console via copy.js
//   * dismissible, auto-closing flashes after controller redirects
//   * the animated "watch emisar work" home-page terminal demo (a no-op
//     on every page that doesn't render it)
//   * restrained on-scroll reveals (a no-op when no [data-reveal] is present)
//   * Escape-to-dismiss + viewport clamping for the shared <.tooltip>,
//     which a pack page's risk pills render — the console gets the same
//     behaviour from the LiveView hook in tooltip.js
//   * on-screen positioning for the shared <.dropdown> panel — a delegated
//     listener, so the console and a server-rendered page wire it identically
//     and neither can grow a panel that opens off the bottom or the edge
//
// The authenticated console loads `app.js` (LiveSocket + hooks) instead;
// `root.html.heex` picks the bundle from the `@app_js?` assign, which the
// global LiveView `on_mount` hook sets on every live render.
import {setupCopyToClipboardDelegation} from "./copy.js"
import {initConsoleCasts} from "./console_cast.js"
import {initDocsFilter} from "./docs_filter.js"
import {initDocsLightbox} from "./docs_lightbox.js"
import {initDocsNavScroll} from "./docs_nav_scroll.js"
import {initDocsToc} from "./docs-toc.js"
import {initDropdowns} from "./dropdown.js"
import {initEmisarDemo} from "./emisar_demo.js"
import {initStaticFlashes} from "./flash.js"
import {initLegalToc} from "./legal_toc.js"
import {initMobileNav} from "./mobile_nav.js"
import {initOsTabs} from "./os_tabs.js"
import {initPackSearch} from "./pack_search.js"
import {initPricingCycle} from "./pricing_cycle.js"
import {initReveal} from "./reveal.js"
import {initScrollFocusable} from "./scroll_focusable.js"
import {initSubscribeGuard} from "./subscribe_guard.js"
import {initTooltips} from "./tooltip.js"

setupCopyToClipboardDelegation()
initStaticFlashes()
initConsoleCasts()
initEmisarDemo()
// The docs shell and the legal pages share the [data-toc-link] TOC contract but
// drive the active state differently, so run exactly one scroll-spy per page —
// the docs sidebar (nav[aria-label="Docs"]) exists only on /docs/* pages.
if (document.querySelector('nav[aria-label="Docs"]')) {
  initDocsToc()
  initDocsNavScroll()
} else {
  initLegalToc()
}
initDocsFilter()
initDocsLightbox()
initDropdowns()
initMobileNav()
initOsTabs()
initPackSearch()
initPricingCycle()
initReveal()
initScrollFocusable()
initSubscribeGuard()
initTooltips()

// Lean JS bundle for the server-rendered marketing site
// (`controllers/marketing_html/*`). Those pages are static and have NO
// LiveView socket, so they must NOT pull in `phoenix_live_view` / the
// LiveSocket / hooks / topbar — that's ~50 KiB of JS the crawler and
// every visitor would download and never use.
//
// Marketing needs exactly two things:
//   * copy-to-clipboard buttons (install snippets, pack detail) — shared
//     with the app console via copy.js
//   * the animated "watch emisar work" home-page terminal demo (a no-op
//     on every page that doesn't render it)
//   * restrained on-scroll reveals (a no-op when no [data-reveal] is present)
//
// The authenticated console loads `app.js` (LiveSocket + hooks) instead;
// `root.html.heex` picks the bundle from the `@app_js?` assign, which the
// global LiveView `on_mount` hook sets on every live render.
import {setupCopyToClipboardDelegation} from "./copy.js"
import {initEmisarDemo} from "./emisar_demo.js"
import {initLegalToc} from "./legal_toc.js"
import {initMobileNav} from "./mobile_nav.js"
import {initPackSearch} from "./pack_search.js"
import {initPricingCycle} from "./pricing_cycle.js"
import {initReveal} from "./reveal.js"
import {initScrollFocusable} from "./scroll_focusable.js"

setupCopyToClipboardDelegation()
initEmisarDemo()
initLegalToc()
initMobileNav()
initPackSearch()
initPricingCycle()
initReveal()
initScrollFocusable()

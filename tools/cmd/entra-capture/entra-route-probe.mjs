// Probe which Entra admin-centre routes are reachable for a session, capturing
// the home page and the navigation that leads to the app blades. Used to find a
// working path when a deep link stops resolving, not to produce guide images.
import { launchChromium, loadEnv, shot, signIn } from './entra-env.mjs'

const env = loadEnv()

const browser = await launchChromium({ headless: true })
const page = await browser.newPage({ viewportSize: { width: 1440, height: 1000 } })

await signIn(page, env)

// chromedp could not render entra.microsoft.com at all; Playwright may. The Entra
// admin center carries Enterprise applications in its left nav, so click through
// and read the resulting URL rather than guessing a blade path again.
await page.goto('https://entra.microsoft.com/', { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(22000)
await shot(page, 'pw-05-entra-home')

for (const label of ['Entra ID', 'Enterprise apps', 'Enterprise applications']) {
  const el = page.getByText(label, { exact: true }).first()
  if (await el.count()) {
    await el.click().catch(() => {})
    await page.waitForTimeout(12000)
    console.log('clicked', label, '->', page.url())
  }
}
await shot(page, 'pw-06-entra-nav')
console.log('URL:', page.url())
console.log((await page.textContent('body')).slice(0, 400))
await browser.close()
console.log('done')

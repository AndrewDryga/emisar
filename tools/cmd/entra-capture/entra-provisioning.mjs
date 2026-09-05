// Capture the enterprise application's Overview and its Provisioning blade —
// the two screens the SCIM guide's setup steps start from. Playwright drives the
// Azure portal, where chromedp only ever rendered its home page.
import { launchChromium, loadEnv, shot, signIn } from './entra-env.mjs'

const env = loadEnv()

const browser = await launchChromium({ headless: true })
const page = await browser.newPage({ viewportSize: { width: 1440, height: 1000 } })

await signIn(page, env)

// The working routes are `#view/<Ext>/<Blade>/~/<Menu>/<params>` — learned by
// reading the URLs the portal itself produced. That exact shape was never tried
// against the IAM extension with an engine that can route.
const SP = '262dd7cc-bfd8-4f0b-aae4-a1bafa0efb46'
const APP = 'd4176f9b-177c-40ff-96ef-b9ddfe950fc1'
const url = `https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Provisioning/objectId/${SP}/appId/${APP}`

await page.goto(url, { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(28000)
await shot(page, 'pw-11-enterprise-overview')

// The blade renders; the deep link normalises to Overview, so reach Provisioning
// through the left menu the way an operator does.
for (const label of ['Manage', 'Provisioning']) {
  const el = page.getByText(label, { exact: true }).first()
  if (await el.count()) { await el.click().catch(() => {}); await page.waitForTimeout(9000) }
}
await page.waitForTimeout(12000)
await shot(page, 'pw-12-provisioning')
const body = await page.textContent('body')
console.log('url:', page.url())
console.log('provisioning UI:', /Provisioning Mode|Admin Credentials|Tenant URL/i.test(body))
console.log(body.slice(0, 300))
await browser.close()
console.log('done')

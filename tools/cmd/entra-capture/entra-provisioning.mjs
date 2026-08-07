// Capture the enterprise application's Overview and its Provisioning blade —
// the two screens the SCIM guide's setup steps start from. Playwright drives the
// Azure portal, where chromedp only ever rendered its home page.
import { launchChromium, loadEnv, totp } from './entra-env.mjs'

const env = loadEnv()

const outline = async (page, text) => {
  await page.evaluate(label => {
    const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
    const hits = [...document.querySelectorAll('*')]
      .filter(el => visible(el) && (el.textContent || '').trim() === label)
    if (!hits.length) return false
    hits.sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)
    const t = hits[0].closest('div,section,li,tr') || hits[0]
    if (t.tagName === 'TR') {
      // Ring the CELLS, not the row. A row's outline paints under its cells'
      // backgrounds, so an opaque table keeps only the part of the ring outside
      // the row — the attribute-mapping shot shipped with just its top edge.
      const cells = [...t.children]
      cells.forEach((cell, i) => {
        const ring = ['inset 0 3px 0 #10b981', 'inset 0 -3px 0 #10b981']
        if (i === 0) ring.push('inset 3px 0 0 #10b981')
        if (i === cells.length - 1) ring.push('inset -3px 0 0 #10b981')
        cell.style.boxShadow = ring.join(', ')
      })
    } else {
      t.style.outline = '3px solid #10b981'
      t.style.outlineOffset = '3px'
      t.style.borderRadius = '6px'
    }
    t.scrollIntoView({ block: 'center' })
    return true
  }, text).catch(() => false)
  await page.waitForTimeout(600)
}

const browser = await launchChromium({ headless: true })
const page = await browser.newPage({ viewportSize: { width: 1440, height: 1000 } })

await page.goto('https://portal.azure.com/', { waitUntil: 'domcontentloaded' })
await page.fill('input[name=loginfmt]', env.ENTRA_ADMIN_USER)
await page.click('#idSIButton9')
await page.waitForSelector('input[name=passwd]', { state: 'visible' })
await page.fill('input[name=passwd]', env.ENTRA_ADMIN_PASSWORD)
await page.click('#idSIButton9')

// Order is not fixed: this tenant shows "Stay signed in?" BEFORE the code prompt.
for (let i = 0; i < 12; i++) {
  await page.waitForTimeout(3000)
  const body = await page.textContent('body').catch(() => '')
  if (/Create a resource|All resources/.test(body)) break
  if (await page.locator('input[name=otc]').count()) {
    if (30 - (Math.floor(Date.now() / 1000) % 30) < 8) await page.waitForTimeout(9000)
    await page.fill('input[name=otc]', totp(env.ENTRA_TOTP_SECRET))
    // The code screen's submit is not #idSIButton9; Enter in the field works on
    // every screen in this sequence.
    await page.press('input[name=otc]', 'Enter')
  } else if (/Stay signed in\?/.test(body)) {
    await page.click('#idBtn_Back').catch(() => {})
  }
}
console.log('signed in')

const shot = async (name) => {
  await page.screenshot({ path: `/tmp/entra/${name}.png` })
  console.log('shot', name)
}

// The working routes are `#view/<Ext>/<Blade>/~/<Menu>/<params>` — learned by
// reading the URLs the portal itself produced. That exact shape was never tried
// against the IAM extension with an engine that can route.
const SP = '262dd7cc-bfd8-4f0b-aae4-a1bafa0efb46'
const APP = 'd4176f9b-177c-40ff-96ef-b9ddfe950fc1'
const url = `https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Provisioning/objectId/${SP}/appId/${APP}`

await page.goto(url, { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(28000)
await shot('pw-11-enterprise-overview')

// The blade renders; the deep link normalises to Overview, so reach Provisioning
// through the left menu the way an operator does.
for (const label of ['Manage', 'Provisioning']) {
  const el = page.getByText(label, { exact: true }).first()
  if (await el.count()) { await el.click().catch(() => {}); await page.waitForTimeout(9000) }
}
await page.waitForTimeout(12000)
await shot('pw-12-provisioning')
const body = await page.textContent('body')
console.log('url:', page.url())
console.log('provisioning UI:', /Provisioning Mode|Admin Credentials|Tenant URL/i.test(body))
console.log(body.slice(0, 300))
await browser.close()
console.log('done')

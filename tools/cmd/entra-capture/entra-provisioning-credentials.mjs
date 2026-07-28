// Capture the Entra-side screens chromedp could not reach: the app Overview
// (client id) and Certificates & secrets. Playwright drives the Azure portal
// where chromedp only ever rendered its home page.
import { chromium } from '/tmp/pw/node_modules/playwright/index.mjs'
import { createHmac } from 'node:crypto'
import { readFileSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/Users/andrewdryga/Projects/os/emisar/portal/.agent/secrets/entra-trial.env', 'utf8')
    .split('\n')
    .filter(l => l && !l.startsWith('#') && l.includes('='))
    .map(l => {
      const [k, ...rest] = l.split('=')
      return [k.trim(), rest.join('=').trim().replace(/^['"]|['"]$/g, '')]
    })
)

// RFC 6238 TOTP, so no phone is in the loop.
const totp = secret => {
  const b32 = secret.toUpperCase().replace(/\s|=/g, '')
  const bits = [...b32].map(c => 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5, '0')).join('')
  const key = Buffer.from(bits.match(/.{8}/g).map(b => parseInt(b, 2)))
  const counter = Buffer.alloc(8)
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)))
  const mac = createHmac('sha1', key).update(counter).digest()
  const off = mac[mac.length - 1] & 0x0f
  return String((mac.readUInt32BE(off) & 0x7fffffff) % 1e6).padStart(6, '0')
}

const outline = async (page, text) => {
  await page.evaluate(label => {
    const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
    const hits = [...document.querySelectorAll('*')]
      .filter(el => visible(el) && (el.textContent || '').trim() === label)
    if (!hits.length) return false
    hits.sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)
    const t = hits[0].closest('div,section,li,tr') || hits[0]
    t.style.outline = '3px solid #10b981'
    t.style.outlineOffset = '3px'
    t.style.borderRadius = '6px'
    t.scrollIntoView({ block: 'center' })
    return true
  }, text).catch(() => false)
  await page.waitForTimeout(600)
}

const browser = await chromium.launch({ headless: true })
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
await page.waitForTimeout(14000)
await shot('pw-12-provisioning')

// Azure renders each blade extension in its OWN IFRAME. That is why body text
// reads as the home shell and every page-level locator found nothing while the
// screenshot plainly showed a form. Work inside the frame instead.
const frames = page.frames()
console.log('frames:', frames.length)
let target = null
for (const f of frames) {
  const t = await f.textContent('body').catch(() => '')
  if (/provisioning|Connect your application|Tenant URL/i.test(t)) {
    target = f
    console.log('MATCH frame:', f.url().slice(0, 110))
  }
}
if (target) {
  const btn = target.locator('button, [role=button], a').filter({ hasText: /Connect your application/i }).first()
  console.log('connect buttons:', await btn.count())
  await btn.click().catch(e => console.log('click:', e.message.slice(0, 80)))
  await page.waitForTimeout(20000)
  await shot('pw-13-connect')
  // Find the frame that actually holds the form, then fill its own inputs — never
  // page-level, which matches the portal's top-bar search first.
  await page.waitForTimeout(4000)
  let form = null
  for (const f of page.frames()) {
    const t = await f.textContent('body').catch(() => '')
    if (/Tenant URL/i.test(t)) { form = f; console.log('form frame:', f.url().slice(0, 90)) }
  }
  if (form) {
    const fields = form.locator('input')
    const n = await fields.count()
    console.log('inputs in form frame:', n)
    for (let i = 0; i < n; i++) {
      const type = await fields.nth(i).getAttribute('type')
      console.log(' input', i, 'type=', type)
    }
    // Tenant URL is the first non-password field on this form.
    for (let i = 0; i < n; i++) {
      if ((await fields.nth(i).getAttribute('type')) !== 'password') {
        await fields.nth(i).fill('https://emisar.dev/scim/v2').catch(e => console.log('fill:', e.message.slice(0, 60)))
        break
      }
    }
    await page.waitForTimeout(2500)
    await shot('pw-16-credentials-filled')
    console.log('filled')
  }
}
await browser.close()
console.log('done')

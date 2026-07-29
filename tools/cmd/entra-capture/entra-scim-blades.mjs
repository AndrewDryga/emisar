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

// Route-guessing for the managed-app blade kept landing on "Dashboard not found",
// so walk it the way a person does: list, open the app, pick Provisioning.
await page.goto('https://portal.azure.com/#blade/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/AllApps',
  { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(25000)
await shot('pw-03-enterprise-apps')

const app = page.getByText('emisar SCIM', { exact: true }).first()
if (await app.count()) {
  await app.click()
  await page.waitForTimeout(20000)
  const prov = page.getByText('Provisioning', { exact: true }).first()
  if (await prov.count()) {
    await prov.click()
    await page.waitForTimeout(20000)
  }
  await shot('pw-04-provisioning')
}
console.log((await page.textContent('body')).slice(0, 500))
await browser.close()
console.log('done')

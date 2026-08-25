// Capture the enterprise application's Overview, its Provisioning blade, and the
// Test-connection result an operator sees after entering the tenant URL and
// secret token. Playwright drives the Azure portal, where chromedp only ever
// rendered its home page.
import { launchChromium, loadEnv, totp } from './entra-env.mjs'
import { mkdirSync } from 'node:fs'

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

const outDir = process.env.ENTRA_CAPTURE_OUT || '/tmp/entra'
mkdirSync(outDir, { recursive: true })
const shot = async (name) => {
  for (const frame of page.frames()) {
    await frame.evaluate(() => {
      const scrub = value => value
        .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '••••••••••••••••••••')
        .replace(/scim\.[a-z0-9.-]+/gi, 'scim.••••••••••••••••••••')
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        node.nodeValue = scrub(node.nodeValue || '')
      }
    }).catch(() => {})
  }
  await page.screenshot({
    path: `${outDir}/${name}.png`,
    clip: { x: 0, y: 42, width: 1440, height: 900 },
  })
  console.log('shot', name)
}

const outlineAcrossFrames = async text => {
  for (const frame of page.frames()) {
    const marked = await frame.evaluate(label => {
      const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
      const hits = [...document.querySelectorAll('*')]
        .filter(el => visible(el) && (el.textContent || '').trim() === label)
        .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)
      if (!hits.length) return false
      const target = hits[0].closest('div,section') || hits[0]
      target.style.outline = '3px solid #10b981'
      target.style.outlineOffset = '3px'
      target.style.borderRadius = '6px'
      return true
    }, text).catch(() => false)
    if (marked) return true
  }
  return false
}

const clickAcrossFrames = async text => {
  for (const frame of page.frames()) {
    const clicked = await frame.evaluate(label => {
      const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
      const hits = [...document.querySelectorAll('button,a,[role=button],[role=menuitem],div')]
        .filter(el => visible(el) && (el.textContent || '').trim() === label)
        .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)
      if (!hits.length) return false
      hits[0].click()
      return true
    }, text).catch(() => false)
    if (clicked) return true
  }
  return false
}

const outlineCredentialPanel = async () => {
  for (const frame of page.frames()) {
    const marked = await frame.evaluate(() => {
      const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
      const anchor = [...document.querySelectorAll('*')]
        .filter(el => visible(el) && (el.textContent || '').trim() === 'Select authentication method:')
        .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0]
      let target = anchor
      for (let up = 0; up < 10 && target; up++, target = target.parentElement) {
        const box = target.getBoundingClientRect()
        if (box.width >= 600 && box.height >= 220 && box.height <= 650) {
          target.style.outline = '3px solid #10b981'
          target.style.outlineOffset = '3px'
          target.style.borderRadius = '6px'
          return true
        }
      }
      return false
    }).catch(() => false)
    if (marked) return true
  }
  return false
}

const markMappingRow = async ({ click = false } = {}) => {
  for (const frame of page.frames()) {
    const marked = await frame.evaluate(({ click }) => {
      const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
      const externalID = [...document.querySelectorAll('*')]
        .filter(el => visible(el) && (el.textContent || '').trim() === 'externalId')
        .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0]
      const row = externalID && externalID.closest('tr,[role=row]')
      if (!row) return false
      row.scrollIntoView({ block: 'center' })
      if (click) {
        const action = row.querySelector('button,a,[role=button]') || row
        action.click()
        return true
      }
      const cells = [...row.children]
      cells.forEach((cell, index) => {
        const ring = ['inset 0 3px 0 #10b981', 'inset 0 -3px 0 #10b981']
        if (index === 0) ring.push('inset 3px 0 0 #10b981')
        if (index === cells.length - 1) ring.push('inset -3px 0 0 #10b981')
        cell.style.boxShadow = ring.join(', ')
      })
      return true
    }, { click }).catch(() => false)
    if (marked) return true
  }
  return false
}

// The working routes are `#view/<Ext>/<Blade>/~/<Menu>/<params>` — learned by
// reading the URLs the portal itself produced. That exact shape was never tried
// against the IAM extension with an engine that can route.
const SP = process.env.ENTRA_SCIM_SERVICE_PRINCIPAL_ID
const APP = process.env.ENTRA_SCIM_APP_ID
if (!SP || !APP) throw new Error('ENTRA_SCIM_SERVICE_PRINCIPAL_ID and ENTRA_SCIM_APP_ID are required')
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
await outlineAcrossFrames('Current cycle status: Incremental sync completed')
await shot('pw-12-provisioning')
if (process.env.ENTRA_CAPTURE_MAPPINGS === '1') {
  for (const label of ['Manage', 'Attribute mapping']) {
    if (await clickAcrossFrames(label)) await page.waitForTimeout(9000)
  }
  if (!(await markMappingRow())) throw new Error('externalId mapping row was not found')
  await shot('pw-17-attribute-mapping')
  if (!(await markMappingRow({ click: true }))) throw new Error('externalId mapping row could not be opened')
  await page.waitForTimeout(12000)
  await page.evaluate(() => {
    const ring = document.createElement('div')
    Object.assign(ring.style, {
      position: 'fixed', left: '38px', top: '314px', width: '765px', height: '55px',
      border: '3px solid #10b981', borderRadius: '6px', boxSizing: 'border-box',
      pointerEvents: 'none', zIndex: '2147483647',
    })
    document.body.appendChild(ring)
  })
  await shot('pw-18-externalid-objectid')
  await browser.close()
  console.log('done')
  process.exit(0)
}
if (process.env.ENTRA_CAPTURE_CONNECTIVITY === '1') {
  for (const label of ['Manage', 'Connectivity']) {
    if (await clickAcrossFrames(label)) await page.waitForTimeout(8000)
  }
  for (const frame of page.frames()) {
    await frame.evaluate(() => {
      for (const input of document.querySelectorAll('input')) {
        if ((input.type || '').toLowerCase() === 'password') input.value = '••••••••••••••••••••'
        if (/^https?:\/\//i.test(input.value || '')) input.value = 'https://emisar.dev/scim/v2'
      }
    }).catch(() => {})
  }
  await outlineCredentialPanel()
  await shot('pw-16-credentials-filled')
  await browser.close()
  console.log('done')
  process.exit(0)
}
if (process.env.ENTRA_CAPTURE_PROVISIONING_ONLY === '1') {
  await browser.close()
  console.log('done')
  process.exit(0)
}

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
    for (let i = 0; i < n; i++) {
      if ((await fields.nth(i).getAttribute('type')) === 'password') {
        await fields.nth(i).evaluate(input => { input.value = '••••••••••••••••••••' })
      }
    }
    await page.waitForTimeout(2500)
    await shot('pw-16-credentials-filled')
    console.log('filled')
  }
}
await browser.close()
console.log('done')

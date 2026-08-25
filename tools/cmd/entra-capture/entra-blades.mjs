// Capture the Entra-side screens chromedp could not reach: the app Overview
// (client id) and Certificates & secrets. Playwright drives the Azure portal
// where chromedp only ever rendered its home page.
import { launchChromium, loadEnv, totp } from './entra-env.mjs'
import { mkdirSync } from 'node:fs'

const env = loadEnv()

const outline = async (page, text) => {
  const marked = await page.evaluate(label => {
    const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
    for (const prior of document.querySelectorAll('[data-emisar-docs-highlight=true]')) {
      prior.remove()
    }
    const hits = [...document.querySelectorAll('*')]
      .filter(el => visible(el) && (el.textContent || '').trim() === label)
    if (!hits.length) return false
    hits.sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)
    const t =
      hits[0].closest('button,a,[role=button],[role=menuitem],li,tr') ||
      hits[0].parentElement ||
      hits[0]
    t.scrollIntoView({ block: 'center' })
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
      const box = t.getBoundingClientRect()
      const ring = document.createElement('div')
      ring.dataset.emisarDocsHighlight = 'true'
      Object.assign(ring.style, {
        position: 'fixed',
        left: `${box.left - 3}px`,
        top: `${box.top - 3}px`,
        width: `${box.width + 6}px`,
        height: `${box.height + 6}px`,
        border: '3px solid #10b981',
        borderRadius: '6px',
        boxSizing: 'border-box',
        pointerEvents: 'none',
        zIndex: '2147483647',
      })
      document.body.appendChild(ring)
    }
    return true
  }, text).catch(() => false)
  if (!marked) throw new Error(`nothing labelled "${text}" to outline`)
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
const maskTenantIdentifiers = async () => {
  for (const frame of page.frames()) {
    await frame.evaluate(() => {
      const scrub = value => value
        .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '••••••••••••••••••••')
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        node.nodeValue = scrub(node.nodeValue || '')
      }
      for (const input of document.querySelectorAll('input')) {
        if (input.value) input.value = scrub(input.value)
      }
    }).catch(() => {})
  }
}
const shot = async (name) => {
  await maskTenantIdentifiers()
  await page.screenshot({
    path: `${outDir}/${name}.png`,
    clip: { x: 0, y: 42, width: 1440, height: 900 },
  })
  console.log('shot', name)
}

const appId = env.ENTRA_CLIENT_ID
// Playwright routes these blades where chromedp only rendered the home page.
await page.goto(
  `https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/${appId}`,
  { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(20000)
await page.getByText('Application (client) ID').first().waitFor({ timeout: 90000 })
await outline(page, 'Application (client) ID')
await shot('pw-01-app-overview')

await page.goto(
  `https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Credentials/appId/${appId}`,
  { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(20000)
await outline(page, 'New client secret')
await shot('pw-02-client-secrets')

await browser.close()
console.log('done')

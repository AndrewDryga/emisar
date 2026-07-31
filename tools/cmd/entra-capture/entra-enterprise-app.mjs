// Capture the two Entra screens the SCIM guide names but never showed: creating
// the enterprise application, and assigning the people to sync.
//
// Both live in the Enterprise applications area rather than App registrations, and
// neither needs a provisioning configuration — which is why they are reachable
// where the Test-connection and attribute-mapping screens were not.
import { chromium } from '/tmp/pw/node_modules/playwright/index.mjs'
import { createHmac } from 'node:crypto'
import { readFileSync, mkdirSync } from 'node:fs'

const env = Object.fromEntries(
  readFileSync('/Users/andrewdryga/Projects/os/emisar/portal/.agent/secrets/entra-trial.env', 'utf8')
    .split('\n')
    .filter(l => l && !l.startsWith('#') && l.includes('='))
    .map(l => {
      const [k, ...rest] = l.split('=')
      return [k.trim(), rest.join('=').trim().replace(/^['"]|['"]$/g, '')]
    })
)

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

// Ring the control a step names. A row's outline paints under its cells'
// backgrounds, so a table row is ringed cell by cell instead.
// `exact` false matches on containment, for a control whose label shares a node with
// a glyph — Azure's toolbar renders "+ Add user/group", so an exact trim never
// equals the label a step names.
const outline = async (page, label, { exact = true } = {}) => {
  // Across every frame, not just the top document. The Azure portal renders a
  // blade's content in an iframe, so a top-level search finds the surrounding
  // navigation and none of the toolbar the step actually names.
  const mark = frame => frame.evaluate(({ text, exact }) => {
    const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0
    const matches = el => {
      const own = (el.textContent || '').trim()
      return exact ? own === text : own.includes(text) && own.length < text.length + 8
    }
    const hits = [...document.querySelectorAll('*')]
      .filter(el => visible(el) && matches(el))
      .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)
    if (!hits.length) return false
    const t = hits[0].closest('div,section,li,tr,button,a') || hits[0]
    if (t.tagName === 'TR') {
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
  }, { text: label, exact }).catch(() => false)

  let marked = false
  for (const frame of page.frames()) {
    if (await mark(frame)) { marked = true; break }
  }

  // FAIL, never warn. A screenshot with no outline is a broken instruction, and
  // that is exactly how bare shots reached the docs before. Say what WAS on the
  // blade, though — "not found" alone cannot tell a renamed control from one whose
  // blade never loaded.
  if (!marked) {
    const frames = page.frames()
    const target = frames[frames.length - 1]
    const visible = await target.evaluate(() => [...document.querySelectorAll('button,[role=button],[role=menuitem],a')]
      .filter(el => (el.offsetWidth > 0 || el.offsetHeight > 0))
      .map(el => (el.textContent || el.getAttribute('aria-label') || '').trim())
      .filter(text => text && text.length < 40)
      .slice(0, 40)).catch(() => [])
    throw new Error(`nothing labelled "${label}" to outline; visible controls: ${JSON.stringify(visible)}`)
  }
  await page.waitForTimeout(600)
}

mkdirSync('/tmp/entra', { recursive: true })

const browser = await chromium.launch({ headless: true })
// An EXPLICIT context, because the second capture needs a second page in the same
// signed-in session and browser.newPage() creates a context that refuses one.
// `viewport`, not `viewportSize` — newContext ignores the latter, so every shot
// came out at Playwright's 1280x720 default while the guide's other Entra images
// are 1520x950.
const context = await browser.newContext({ viewport: { width: 1520, height: 950 } })
const page = await context.newPage()

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
    await page.press('input[name=otc]', 'Enter')
  } else if (/Stay signed in\?/.test(body)) {
    await page.click('#idBtn_Back').catch(() => {})
  }
}
console.log('signed in')

const shot = async name => {
  await page.screenshot({ path: `/tmp/entra/${name}.png` })
  console.log('shot', name)
}

// 1. Creating the enterprise application. "Create your own application" is the
// path for a SCIM app: the gallery entries are for products Microsoft already
// knows, and emisar is not one of them.
await page.goto(
  'https://portal.azure.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview',
  { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(20000)
await page.getByText('New application').first().waitFor({ timeout: 90000 })
await page.getByText('New application').first().click()
await page.waitForTimeout(12000)
await page.getByText('Create your own application').first().waitFor({ timeout: 90000 })
await outline(page, 'Create your own application')
await shot('pw-10-create-enterprise-app')

// 2. Assigning the people to sync. Users and groups on the app decides who is in
// scope; provisioning only ever pushes what is assigned here.
//
// Walked the way a person does, not by route: the managed-app blade needs the
// enterprise application's OBJECT id, which is not the client id and is nowhere in
// the credentials file — guessing the route lands on "Dashboard not found".
// A FRESH page in the same signed-in context. Hash-navigating away from the
// gallery left the SPA wedged — the application list sat on its spinner past three
// minutes — and closing the blade with Escape did not clear it. A new page starts
// the portal clean while keeping the session.
const page2 = await context.newPage()

await page2.goto('https://portal.azure.com/#blade/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/AllApps',
  { waitUntil: 'domcontentloaded' })
await page2.waitForTimeout(20000)

// Dismiss the portal's NPS survey if it appears; it steals focus over the list.
await page2.locator('button[aria-label="Close"]').first().click({ timeout: 3000 }).catch(() => {})

// The direct route lands on the shell with nothing selected — the list only loads
// once "All applications" under Manage is actually chosen.
const manage = page2.getByText('Manage', { exact: true }).first()

if (await manage.count()) {
  await manage.click().catch(() => {})
  await page2.waitForTimeout(6000)
}

const allApps = page2.getByText('All applications', { exact: true }).first()

if (await allApps.count()) {
  await allApps.click().catch(() => {})
  await page2.waitForTimeout(20000)
}

// WAIT for the row, do not sample after a fixed pause. The application list was
// still showing its spinner at 30 seconds, and a count taken then reports the app
// as absent when it is merely late.
const app = page2.getByText('emisar SCIM', { exact: true }).first()

try {
  await app.waitFor({ timeout: 180000 })
} catch (error) {
  await page2.screenshot({ path: '/tmp/entra/pw-11-app-not-listed.png' })
  throw new Error('the emisar SCIM enterprise application never appeared in the list')
}

await app.click()
await page2.waitForTimeout(20000)

// The blade's menu item is present but HIDDEN — the app menu renders collapsed, so
// Playwright waited on visibility that never came (182 attempts, all resolving to a
// hidden div). Click the node itself.
const opened = await page2.evaluate(() => {
  const item = [...document.querySelectorAll('.fxc-menu-listView-item, [data-telemetryname]')]
    .find(el => (el.textContent || '').trim() === 'Users and groups')
  if (!item) return false
  item.click()
  return true
})

if (!opened) throw new Error('the app blade has no Users and groups item')

await page2.waitForTimeout(8000)

// Twice, and both are needed. The first click lands on a collapsed menu and only
// expands it — the blade stayed on Overview. With the item now visible, a real
// click routes.
const usersItem = page2.getByText('Users and groups', { exact: true }).first()

await usersItem.waitFor({ timeout: 90000 })
await usersItem.click()
await page2.waitForTimeout(25000)
// No locator wait here. The blade is already on Users and groups by this point and
// the toolbar item is visible, but getByText timed out on it — the outline helper
// searches every element and throws when it finds nothing, which is the check that
// matters.
await outline(page2, 'Add user/group', { exact: false })
await page2.screenshot({ path: '/tmp/entra/pw-11-assign-users.png' })
console.log('shot pw-11-assign-users')

await browser.close()
console.log('done')

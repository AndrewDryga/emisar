// What this rig has left in the Entra tenant, and optionally removing it.
//
// The capture scripts here create enterprise applications and never had a way to
// say so, which is how leftovers accumulated until the founder found them by hand
// — see .agent/kb/rules/shared-capture-rigs-own-what-they-create.md.
//
// Every application is printed with a verdict beside it. A filter that can
// silently under-match must show what it looked at; "nothing to clean up" from a
// filter that matched nothing is not evidence of a clean tenant.
//
//   node entra-inventory.mjs            # list only
//   node entra-inventory.mjs --delete   # list, then remove the ones that are ours
import { chromium } from '/tmp/pw/node_modules/playwright/index.mjs'
import { createHmac } from 'node:crypto'
import { readFileSync } from 'node:fs'

const remove = process.argv.includes('--delete')

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

const browser = await chromium.launch({ headless: true })
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

// Graph, not the portal's DOM. The portal renders blades in iframes and its list
// is virtualised; Graph answers the same question directly.
//
// Take the token by watching the portal authenticate its OWN calls, rather than
// posting to an internal token endpoint whose contract we'd be guessing at. That
// guess returned nothing, and a token fetch that quietly yields '' is one edit
// away from reporting an empty tenant as a clean one.
const tokens = new Map()
page.on('request', request => {
  const auth = request.headers()['authorization']
  if (!auth || !/^bearer /i.test(auth)) return
  if (request.url().includes('graph.microsoft.com')) tokens.set('graph', auth)
})

// Enterprise applications is the blade that lists what these rigs create, so
// loading it is what makes the portal go and read that list.
await page.goto(
  'https://portal.azure.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview',
  { waitUntil: 'domcontentloaded' },
)
for (let i = 0; i < 30 && !tokens.has('graph'); i++) await page.waitForTimeout(2000)
const token = tokens.get('graph') || ''

if (!token) {
  console.log('could not obtain a Graph token from the portal session — cannot list the tenant')
  console.log('WITHOUT A LISTING THIS TENANT CANNOT BE CALLED CLEAN')
  await browser.close()
  process.exit(1)
}

const graph = async (path, method = 'GET') => {
  const response = await page.evaluate(async ({ path, method, token }) => {
    const r = await fetch('https://graph.microsoft.com/v1.0' + path, {
      method,
      headers: { authorization: token, accept: 'application/json' },
    })
    return { status: r.status, body: r.status === 204 ? null : await r.json().catch(() => null) }
  }, { path, method, token })
  return response
}

const listing = await graph("/servicePrincipals?$select=id,displayName,appId,servicePrincipalType&$top=200")
if (listing.status !== 200) {
  console.log(`Graph refused the listing: ${listing.status}`)
  console.log('WITHOUT A LISTING THIS TENANT CANNOT BE CALLED CLEAN')
  await browser.close()
  process.exit(1)
}

// Ours by the names these scripts use. Everything else is printed and left alone.
const ours = app => /emisar/i.test(app.displayName || '')

console.log('--- every enterprise application, and what this run will do with it ---')
const apps = listing.body.value || []
for (const app of apps) {
  console.log(`  ${ours(app) ? 'DELETE ' : 'spare  '} ${(app.displayName || '').padEnd(44)} ${app.id}`)
}
console.log('--- anything spared that this rig created is a filter gap, not a clean tenant ---')

const mine = apps.filter(ours)
console.log(`${apps.length} enterprise applications, ${mine.length} of them ours`)

if (remove) {
  for (const app of mine) {
    const deleted = await graph(`/servicePrincipals/${app.id}`, 'DELETE')
    console.log(`  removed ${app.displayName}: ${deleted.status}`)
  }
}

await browser.close()

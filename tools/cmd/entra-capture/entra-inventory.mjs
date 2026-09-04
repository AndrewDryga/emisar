// What this rig has left in the Entra tenant, and optionally removing it.
//
// The capture scripts here create objects in TWO places and never had a way to
// say so, which is how leftovers accumulated until the founder found them by hand
// — see .agent/kb/rules/shared-capture-rigs-own-what-they-create.md:
//
//   - app registrations named "emisar" (main.go's register form — seven duplicates
//     accumulated before the list blade's failure to render made them visible),
//   - enterprise applications such as "emisar SCIM" ("New application" →
//     "Create your own application" in the .mjs scripts).
//
// Every object in both collections is printed with a verdict beside it. A filter
// that can silently under-match must show what it looked at; "nothing to clean
// up" from a filter that matched nothing is not evidence of a clean tenant.
//
//   node entra-inventory.mjs            # list only
//   node entra-inventory.mjs --delete   # list, then remove the ones that are ours
import { launchChromium, loadEnv, signIn } from './entra-env.mjs'

const remove = process.argv.includes('--delete')

const env = loadEnv()

const browser = await launchChromium({ headless: true })
const context = await browser.newContext({ viewport: { width: 1520, height: 950 } })
const page = await context.newPage()

await signIn(page, env)

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
  const url = path.startsWith('https://') ? path : 'https://graph.microsoft.com/v1.0' + path
  const response = await page.evaluate(async ({ url, method, token }) => {
    const r = await fetch(url, {
      method,
      headers: { authorization: token, accept: 'application/json' },
    })
    return { status: r.status, body: r.status === 204 ? null : await r.json().catch(() => null) }
  }, { url, method, token })
  return response
}

// Follow @odata.nextLink to the last page. A page cap under-lists exactly as
// silently as a bad filter: 200 rows fit today's tenant, and the day they don't,
// a truncated listing reads as a clean one.
const listAll = async path => {
  const rows = []
  let next = path
  while (next) {
    const listing = await graph(next)
    if (listing.status !== 200) return { status: listing.status, rows: null }
    rows.push(...(listing.body.value || []))
    next = listing.body['@odata.nextLink'] || null
  }
  return { status: 200, rows }
}

// Ours by the names these scripts use. The one keeper is identified by something
// it carries, never by a name the filter happens to miss: the saved walkthrough
// app registration (and its service principal) whose appId is ENTRA_CLIENT_ID —
// main.go and entra-blades.mjs reuse that app by id instead of registering yet
// another duplicate, so deleting it breaks the next capture run.
const keeper = row => Boolean(env.ENTRA_CLIENT_ID) && row.appId === env.ENTRA_CLIENT_ID
const ours = row => /emisar/i.test(row.displayName || '') && !keeper(row)
const verdict = row => (keeper(row) ? 'keep   ' : ours(row) ? 'DELETE ' : 'spare  ')

// Both halves of what the rig creates. Deleting an application also takes its
// service principal with it, so the cleanup below removes service principals
// FIRST — a delete against a row that just vanished reads as a failure it isn't.
const sections = [
  { label: 'app registrations', resource: 'applications', select: 'id,appId,displayName' },
  { label: 'enterprise applications', resource: 'servicePrincipals', select: 'id,appId,displayName,servicePrincipalType' },
]

const collections = []
for (const section of sections) {
  const listing = await listAll(`/${section.resource}?$select=${section.select}&$top=200`)
  if (listing.status !== 200) {
    console.log(`Graph refused the ${section.label} listing: ${listing.status}`)
    console.log('WITHOUT A LISTING THIS TENANT CANNOT BE CALLED CLEAN')
    await browser.close()
    process.exit(1)
  }

  console.log(`--- every ${section.label.replace(/s$/, '')}, and what this run will do with it ---`)
  for (const row of listing.rows) {
    console.log(`  ${verdict(row)} ${(row.displayName || '').padEnd(44)} ${row.id}`)
  }
  console.log('--- anything spared that this rig created is a filter gap, not a clean tenant ---')

  const mine = listing.rows.filter(ours)
  console.log(`${listing.rows.length} ${section.label}, ${mine.length} of them ours`)
  collections.push({ ...section, mine })
}

if (remove) {
  let failed = 0
  for (const { resource, mine } of [...collections].reverse()) {
    for (const row of mine) {
      const deleted = await graph(`/${resource}/${row.id}`, 'DELETE')
      if (deleted.status !== 204) failed++
      console.log(`  removed ${row.displayName} (${resource}): ${deleted.status}`)
    }
  }
  if (failed > 0) {
    console.log(`${failed} delete(s) did not return 204 — THIS TENANT CANNOT BE CALLED CLEAN`)
    await browser.close()
    process.exit(1)
  }
}

await browser.close()

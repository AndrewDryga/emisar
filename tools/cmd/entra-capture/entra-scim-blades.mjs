// Capture the Enterprise applications list and the Provisioning blade reached
// through it — the navigation half of the SCIM guide, as opposed to the
// deep-linked screens the other rigs shoot.
import { launchChromium, loadEnv, shot, signIn } from './entra-env.mjs'

const env = loadEnv()

const browser = await launchChromium({ headless: true })
const page = await browser.newPage({ viewportSize: { width: 1440, height: 1000 } })

await signIn(page, env)

// Route-guessing for the managed-app blade kept landing on "Dashboard not found",
// so walk it the way a person does: list, open the app, pick Provisioning.
await page.goto('https://portal.azure.com/#blade/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/AllApps',
  { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(25000)
await shot(page, 'pw-03-enterprise-apps')

const app = page.getByText('emisar SCIM', { exact: true }).first()
if (await app.count()) {
  await app.click()
  await page.waitForTimeout(20000)
  const prov = page.getByText('Provisioning', { exact: true }).first()
  if (await prov.count()) {
    await prov.click()
    await page.waitForTimeout(20000)
  }
  await shot(page, 'pw-04-provisioning')
}
console.log((await page.textContent('body')).slice(0, 500))
await browser.close()
console.log('done')

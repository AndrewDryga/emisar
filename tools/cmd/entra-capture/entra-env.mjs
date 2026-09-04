// Shared setup for the Entra capture rigs.
//
// Each rig used to open with the same three things: a Playwright import bound to
// one machine's scratch directory, a dotenv parser, and an RFC 6238 TOTP. Two of
// those were absolute paths — /tmp/pw and a maintainer's home — so the scripts
// were unrunnable by anyone else and published that layout from a public repo.
// Resolve both instead, and keep the copies in one place.

import { createHmac } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))

// Playwright is pinned by this directory's package.json + package-lock.json, so
// it rides the same weekly Dependabot cadence and release-age gate as every
// other dependency in a security product — it used to be `npm i -g playwright`
// into whatever the maintainer's global root held, executed with a live tenant's
// admin password and TOTP seed in process memory. Resolution still goes through
// the import so a rig run from elsewhere says what is missing, rather than
// failing on a module-not-found for a hardcoded path.
//
//	npm --prefix tools/cmd/entra-capture ci
export const launchChromium = async options => {
  const from = process.env.EMISAR_PLAYWRIGHT || 'playwright'
  const executablePath = process.env.EMISAR_CHROMIUM_EXECUTABLE
  let playwright
  try {
    playwright = await import(from)
  } catch (cause) {
    throw new Error(
      `cannot load Playwright from ${JSON.stringify(from)}. Install the pinned ` +
        'version with `npm --prefix tools/cmd/entra-capture ci`, or point ' +
        'EMISAR_PLAYWRIGHT at its index.mjs.',
      { cause }
    )
  }
  return playwright.chromium.launch(executablePath ? { ...options, executablePath } : options)
}

// The credentials live outside the repo tree by design. Default to the path the
// walkthrough documents, relative to this file, and let an env var move it.
export const loadEnv = () => {
  const file =
    process.env.ENTRA_ENV_FILE ||
    resolve(here, '..', '..', '..', 'portal', '.agent', 'secrets', 'entra-trial.env')
  let text
  try {
    text = readFileSync(file, 'utf8')
  } catch (cause) {
    throw new Error(
      `cannot read the Entra credentials at ${file}. Set ENTRA_ENV_FILE to point at them.`,
      { cause }
    )
  }
  return Object.fromEntries(
    text
      .split('\n')
      .filter(l => l && !l.startsWith('#') && l.includes('='))
      .map(l => {
        const [k, ...rest] = l.split('=')
        return [k.trim(), rest.join('=').trim().replace(/^['"]|['"]$/g, '')]
      })
  )
}

// RFC 6238 TOTP, so no phone is in the loop.
export const totp = secret => {
  const b32 = secret.toUpperCase().replace(/\s|=/g, '')
  const bits = [...b32].map(c => 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5, '0')).join('')
  const key = Buffer.from(bits.match(/.{8}/g).map(b => parseInt(b, 2)))
  const counter = Buffer.alloc(8)
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)))
  const mac = createHmac('sha1', key).update(counter).digest()
  const off = mac[mac.length - 1] & 0x0f
  return String((mac.readUInt32BE(off) & 0x7fffffff) % 1e6).padStart(6, '0')
}

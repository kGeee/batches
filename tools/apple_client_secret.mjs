#!/usr/bin/env node
// Makes the "Secret Key (for OAuth)" that Supabase's Apple provider needs for web sign-in.
// Apple caps it at six months, so run this again before it expires.
//
//   node tools/apple_client_secret.mjs <AuthKey_XXXX.p8> <key id> <services id> [team id]
//
// The .p8 is a Sign in with Apple key from developer.apple.com → Keys. Keep it out of git.
import { createPrivateKey, sign } from 'node:crypto'
import { readFileSync } from 'node:fs'

const [keyPath, keyID, servicesID, teamID = '7CK43PG7GZ'] = process.argv.slice(2)
if (!keyPath || !keyID || !servicesID) {
  console.error('usage: node tools/apple_client_secret.mjs <AuthKey.p8> <key id> <services id> [team id]')
  process.exit(1)
}

const b64 = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url')
const now = Math.floor(Date.now() / 1000)
const expires = now + 180 * 24 * 60 * 60 - 60
const head = b64({ alg: 'ES256', kid: keyID })
const body = b64({ iss: teamID, iat: now, exp: expires, aud: 'https://appleid.apple.com', sub: servicesID })
const signature = sign('sha256', Buffer.from(`${head}.${body}`), {
  key: createPrivateKey(readFileSync(keyPath)), dsaEncoding: 'ieee-p1363',
}).toString('base64url')

console.log(`${head}.${body}.${signature}`)
console.error(`Expires ${new Date(expires * 1000).toISOString().slice(0, 10)}.`)

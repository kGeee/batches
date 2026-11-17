// Sends an APNs alert for one row of `notifications`.
//
// Called by the database (private.queue_push, via pg_net) right after a notification is inserted,
// with only the notification's id. Everything else (the text, who may see it, the badge, the
// recipient's devices) comes from public.push_payload, which runs as the recipient so a push never
// says more than the app would show them. Tokens Apple reports as dead are deleted.
//
// Secrets (supabase secrets set ...):
//   PUSH_WEBHOOK_SECRET   shared with the database (vault secret push_webhook_secret)
//   APNS_KEY_ID           the 10-character key ID of the .p8 key
//   APNS_TEAM_ID          the Apple developer team ID
//   APNS_PRIVATE_KEY      the .p8 file's contents, BEGIN/END lines included
//   APNS_BUNDLE_ID        optional, defaults to com.kevingeorge.strewn
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform.

import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

type Device = { token: string; environment: 'sandbox' | 'production' }
type Payload = {
  title: string
  body: string
  badge: number
  thread: string | null
  notification_id: string
  collection_id: string | null
  photo_id: string | null
  actor_handle: string | null
  devices: Device[]
}

const env = (name: string) => {
  const value = Deno.env.get(name)
  if (!value) throw new Error(`missing secret ${name}`)
  return value
}

const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false },
})

// APNs provider token: an ES256 JWT, valid for up to an hour; Apple asks for it to be reused, not
// minted per request, and refreshed no more than every 20 minutes.
let cached: { jwt: string; at: number } | null = null
let signingKey: CryptoKey | null = null

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  if (cached && now - cached.at < 40 * 60) return cached.jwt
  if (!signingKey) {
    const pem = env('APNS_PRIVATE_KEY').replace(/\\n/g, '\n')
    const der = Uint8Array.from(
      atob(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')),
      (c) => c.charCodeAt(0),
    )
    signingKey = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  }
  const encode = (o: unknown) => base64url(new TextEncoder().encode(JSON.stringify(o)))
  const unsigned = `${encode({ alg: 'ES256', kid: env('APNS_KEY_ID') })}.${encode({ iss: env('APNS_TEAM_ID'), iat: now })}`
  // WebCrypto's ECDSA signature is already the raw r||s form JWS expects.
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, signingKey, new TextEncoder().encode(unsigned)),
  )
  cached = { jwt: `${unsigned}.${base64url(signature)}`, at: now }
  return cached.jwt
}

async function send(device: Device, p: Payload): Promise<{ status: number; reason?: string }> {
  const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'
  const body = {
    aps: {
      alert: { title: p.title, body: p.body },
      sound: 'default',
      badge: p.badge,
      ...(p.thread ? { 'thread-id': p.thread } : {}),
    },
    // Read by PushNotifications.userNotificationCenter(_:didReceive:) to open the right screen.
    notification_id: p.notification_id,
    ...(p.collection_id ? { collection_id: p.collection_id } : {}),
    ...(p.photo_id ? { photo_id: p.photo_id } : {}),
    ...(p.actor_handle ? { actor_handle: p.actor_handle } : {}),
  }
  const response = await fetch(`https://${host}/3/device/${device.token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${await providerToken()}`,
      'apns-topic': Deno.env.get('APNS_BUNDLE_ID') ?? 'com.kevingeorge.strewn',
      'apns-push-type': 'alert',
      'apns-priority': '10',
      // A re-sent notification (a like undone and redone) replaces the earlier alert.
      'apns-collapse-id': p.notification_id,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  })
  if (response.ok) {
    await response.body?.cancel()
    return { status: response.status }
  }
  const reason = await response.json().then((j) => j.reason as string).catch(() => undefined)
  return { status: response.status, reason }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  if (req.headers.get('authorization') !== `Bearer ${env('PUSH_WEBHOOK_SECRET')}`) {
    return new Response('unauthorized', { status: 401 })
  }

  const { id } = await req.json().catch(() => ({ id: null }))
  if (typeof id !== 'string') return new Response('missing id', { status: 400 })

  const { data, error } = await supabase.rpc('push_payload', { p_notification: id })
  if (error) {
    console.error('push_payload', id, error.message)
    return new Response('payload failed', { status: 500 })
  }
  const payload = data as Payload | null
  if (!payload || payload.devices.length === 0) return Response.json({ sent: 0 })

  const results = await Promise.all(payload.devices.map((d) => send(d, payload).then((r) => ({ ...r, device: d }))))

  // 410: the app was removed or the token expired. BadDeviceToken: a token for the other APNs
  // environment, or garbage. Either way it will never work again.
  const dead = results
    .filter((r) => r.status === 410 || r.reason === 'BadDeviceToken' || r.reason === 'Unregistered')
    .map((r) => r.device.token)
  if (dead.length) await supabase.from('device_tokens').delete().in('token', dead)

  for (const r of results.filter((r) => r.status >= 400)) {
    console.warn('apns', r.status, r.reason, r.device.environment, r.device.token.slice(0, 8))
  }
  return Response.json({ sent: results.filter((r) => r.status < 300).length, removed: dead.length })
})

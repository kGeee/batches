// Sends a postcard the browser has already drawn: reads the caller's row in postcards, gives Lob
// short-lived links to its two PDFs in the prints bucket, and records what Lob answered.
//
// Secrets (supabase secrets set ...):
//   LOB_API_KEY   a Lob secret key. A test key (test_...) has Lob render the card and give back a
//                 proof, and nothing is printed or mailed. A live key (live_...) mails it, so with
//                 one set, only cards marked paid are sent; nothing marks a card paid yet.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform.
//
// The caller is signed in (verify_jwt stays on) and can only send their own card. Sending is
// idempotent: Lob gets the card's id as its Idempotency-Key, and a card that's already sent just
// answers with what was recorded.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

const env = (name: string) => Deno.env.get(name)?.trim() ?? ''

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false },
})

type Card = Record<string, any>
const answer = (c: Card) => ({
  id: c.id, status: c.status, lobEnv: c.lob_env, proofUrl: c.proof_url,
  expectedDelivery: c.expected_delivery, failure: c.failure,
})

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405)

  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? ''
  const { data: who } = await supabase.auth.getUser(token)
  const userID = who?.user?.id
  if (!userID) return json({ error: 'sign in to send a postcard' }, 401)

  const { postcardID } = await req.json().catch(() => ({ postcardID: null }))
  if (typeof postcardID !== 'string') return json({ error: 'which postcard?' }, 400)

  const { data: card, error } = await supabase.from('postcards').select().eq('id', postcardID).eq('user_id', userID).maybeSingle()
  if (error) return json({ error: 'could not read the postcard' }, 500)
  if (!card) return json({ error: 'no such postcard' }, 404)
  if (!['requested', 'paid'].includes(card.status)) return json(answer(card))

  const key = env('LOB_API_KEY')
  if (!key) return json({ ...answer(card), error: 'mailing is not set up yet' }, 503)
  const live = key.startsWith('live_')
  if (live && card.status !== 'paid') return json({ ...answer(card), error: 'this postcard has not been paid for' }, 402)

  const link = async (path: string) => {
    const { data } = await supabase.storage.from('prints').createSignedUrl(path, 60 * 60)
    return data?.signedUrl ?? null
  }
  const [front, back] = await Promise.all([link(card.front_path), link(card.back_path)])
  if (!front || !back) return json({ error: 'the postcard files are missing' }, 409)

  const res = await fetch('https://api.lob.com/v1/postcards', {
    method: 'POST',
    headers: {
      Authorization: `Basic ${btoa(`${key}:`)}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': card.id,
    },
    body: JSON.stringify({
      description: 'Batches postcard',
      to: {
        name: card.to_name,
        address_line1: card.to_line1,
        ...(card.to_line2 ? { address_line2: card.to_line2 } : {}),
        address_city: card.to_city,
        address_state: card.to_state,
        address_zip: card.to_zip,
        address_country: 'US',
      },
      front,
      back,
      size: '4x6',
      mail_type: 'usps_first_class',
      // A personal note someone chose to send, not advertising.
      use_type: 'operational',
      metadata: { postcard_id: card.id },
    }),
  })
  const body = await res.json().catch(() => ({}))

  if (!res.ok) {
    // Lob's errors carry a message for developers; the exact shape isn't documented, so look in both places.
    const why = String(body?.error?.message ?? body?.message ?? `Lob answered ${res.status}`).slice(0, 500)
    console.error('postcard-send: Lob answered', res.status, why)
    const { data: failed } = await supabase.from('postcards')
      .update({ status: 'failed', failure: why, lob_env: live ? 'live' : 'test' })
      .eq('id', card.id).select().single()
    return json({ ...answer(failed ?? card), error: why }, res.status >= 500 ? 502 : 422)
  }

  const { data: sent } = await supabase.from('postcards').update({
    status: 'sent',
    lob_id: body.id ?? null,
    lob_env: live ? 'live' : 'test',
    proof_url: body.url ?? null,
    expected_delivery: body.expected_delivery_date ?? null,
    sent_at: new Date().toISOString(),
    failure: null,
  }).eq('id', card.id).select().single()
  return json(answer(sent ?? { ...card, status: 'sent' }))
})

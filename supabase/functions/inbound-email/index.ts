// Mail sent to any address at batches.space reaches Resend (the domain's MX record points there),
// and Resend calls this function for each message with an `email.received` webhook. The webhook
// carries only metadata, so the message itself (body, attachments, headers) is forwarded on to the
// inbox in FORWARD_TO by Resend's forward call.
//
// Secrets (supabase secrets set ...):
//   RESEND_API_KEY          a Resend API key that can send from batches.space
//   RESEND_WEBHOOK_SECRET   the signing secret of the Resend webhook that calls this function
//   FORWARD_TO              where mail ends up, e.g. a Gmail address (comma-separate several)
//   FORWARD_FROM            optional; the sender forwards appear from (default below)
//
// Called by Resend, not a signed-in user: verify_jwt is off for it in supabase/config.toml, and
// every request must carry a valid Resend (Svix) signature instead.
import { Resend } from 'npm:resend@6.38.1'

const env = (name: string) => Deno.env.get(name)?.trim() ?? ''

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })

  const apiKey = env('RESEND_API_KEY')
  const webhookSecret = env('RESEND_WEBHOOK_SECRET')
  const forwardTo = env('FORWARD_TO').split(',').map((s) => s.trim()).filter(Boolean)
  if (!apiKey || !webhookSecret || !forwardTo.length) {
    console.error('inbound-email: RESEND_API_KEY, RESEND_WEBHOOK_SECRET and FORWARD_TO must be set')
    // 503 so Resend keeps retrying until the secrets are in place, rather than dropping mail.
    return new Response('not configured', { status: 503 })
  }
  const resend = new Resend(apiKey)

  // The signature covers the raw body exactly as sent, so verify before parsing.
  const payload = await req.text()
  let event
  try {
    event = resend.webhooks.verify({
      payload,
      headers: {
        id: req.headers.get('svix-id') ?? '',
        timestamp: req.headers.get('svix-timestamp') ?? '',
        signature: req.headers.get('svix-signature') ?? '',
      },
      webhookSecret,
    })
  } catch {
    return new Response('invalid signature', { status: 400 })
  }

  if (event.type !== 'email.received') return new Response('ignored')
  const emailId = (event.data as { email_id?: string }).email_id
  if (!emailId) return new Response('no email id', { status: 400 })

  const { data, error } = await resend.emails.receiving.forward(
    {
      emailId,
      to: forwardTo,
      from: env('FORWARD_FROM') || 'Batches inbox <inbox@batches.space>',
    },
    // Resend retries webhooks it thinks failed; the same email is only ever forwarded once.
    { idempotencyKey: `forward/${emailId}` },
  )
  if (error) {
    console.error('inbound-email: forward failed', emailId, error.message)
    return new Response(error.message, { status: 502 })
  }
  console.log('inbound-email: forwarded', emailId, '->', data?.id)
  return Response.json({ forwarded: data?.id })
})

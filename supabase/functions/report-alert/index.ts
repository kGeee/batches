// Emails you when someone reports a person, batch, photo or comment, so a report gets looked at
// within the day Apple expects instead of waiting to be noticed in the dashboard.
//
// Called by the database (private.queue_report_alert, via pg_net) right after a report is
// inserted, with only the report's id; the report itself is read here with the service role.
//
// Secrets (supabase secrets set ...):
//   PUSH_WEBHOOK_SECRET   the database's shared webhook secret (vault secret push_webhook_secret)
//   RESEND_API_KEY        a Resend API key that can send from batches.space (shared with inbound-email)
//   REPORT_ALERT_TO       optional; who gets the alert (comma-separate several). Defaults to FORWARD_TO.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'
import { Resend } from 'npm:resend@6.38.1'

const env = (name: string) => Deno.env.get(name)?.trim() ?? ''

const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false },
})

const escape = (s: unknown) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  const secret = env('PUSH_WEBHOOK_SECRET')
  if (!secret || req.headers.get('authorization') !== `Bearer ${secret}`) {
    return new Response('unauthorized', { status: 401 })
  }

  const apiKey = env('RESEND_API_KEY')
  const to = (env('REPORT_ALERT_TO') || env('FORWARD_TO')).split(',').map((s) => s.trim()).filter(Boolean)
  if (!apiKey || !to.length) {
    console.error('report-alert: RESEND_API_KEY and REPORT_ALERT_TO (or FORWARD_TO) must be set')
    return new Response('not configured', { status: 503 })
  }

  const { id } = await req.json().catch(() => ({ id: null }))
  if (typeof id !== 'string') return new Response('missing id', { status: 400 })

  const { data: r, error } = await supabase.from('reports').select('*').eq('id', id).maybeSingle()
  if (error || !r) {
    console.error('report-alert: report', id, error?.message ?? 'not found')
    return new Response('report not found', { status: 404 })
  }

  const ctx = (r.context ?? {}) as Record<string, string>
  const what = r.comment_id ? 'comment' : r.photo_id ? 'photo' : r.collection_id ? 'batch' : 'person'
  const who = ctx.reported_handle ? `@${ctx.reported_handle}` : 'someone'
  const project = new URL(env('SUPABASE_URL')).hostname.split('.')[0]

  const rows: [string, unknown][] = [
    ['Reason', r.reason],
    ['Details', r.details],
    ['Reported', `${what} by ${who}`],
    ['Reported by', ctx.reporter_handle ? `@${ctx.reporter_handle}` : null],
    ['Batch', ctx.batch_title],
    ['Comment', ctx.comment_body],
    ['Photo copies', ctx.photo_share_path],
    ['Batch id', r.collection_id],
    ['Photo id', r.photo_id],
    ['Comment id', r.comment_id],
    ['Person id', r.reported_user_id],
    ['Report id', r.id],
    ['When', new Date(r.created_at).toUTCString()],
  ]
  const shown = rows.filter(([, v]) => v !== null && v !== undefined && v !== '')
  const dashboard = `https://supabase.com/dashboard/project/${project}/editor`

  const { error: sendError } = await new Resend(apiKey).emails.send(
    {
      from: 'Batches reports <reports@batches.space>',
      to,
      subject: `Report: ${r.reason} — ${what} by ${who}`,
      text: [
        ...shown.map(([k, v]) => `${k}: ${v}`),
        '',
        `Review it in Supabase → Table Editor → reports: ${dashboard}`,
        "Apple expects reports to be acted on within a day. Set status to 'actioned' or 'dismissed' when done.",
      ].join('\n'),
      html: `<table cellpadding="4" style="font:14px -apple-system,sans-serif;border-collapse:collapse">${
        shown.map(([k, v]) => `<tr><td style="color:#777;vertical-align:top">${escape(k)}</td><td>${escape(v)}</td></tr>`).join('')
      }</table><p style="font:14px -apple-system,sans-serif">Review it in <a href="${dashboard}">Supabase → Table Editor → reports</a>. Apple expects reports to be acted on within a day; set <code>status</code> to <code>actioned</code> or <code>dismissed</code> when done.</p>`,
    },
    // pg_net doesn't retry, but a resend of the same report should never email twice.
    { idempotencyKey: `report/${r.id}` },
  )
  if (sendError) {
    console.error('report-alert: send failed', id, sendError.message)
    return new Response(sendError.message, { status: 502 })
  }
  return Response.json({ sent: true })
})

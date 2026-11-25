// Prices a book order with Gelato and sends it there. The browser has already made the print file
// and saved the order with its shipping address; this reads that row as the signed-in owner and
// writes back what Gelato answered.
//
//   { action: 'quote', orderID }   what Gelato charges to print and ship it, cheapest shipping
//   { action: 'place', orderID }   creates the order at Gelato
//
// Until payment exists, every order goes to Gelato as a draft: Gelato keeps it, never prints it,
// and it can be confirmed (PATCH /v4/orders/{id} with orderType "order") or deleted in Gelato's
// dashboard. An order marked paid goes as a real order; nothing marks one paid yet.
//
// Secrets: GELATO_API_KEY and GELATO_PHOTOBOOK_UID, as for print-cover. SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are provided by the platform.
//
// pageCount is the book's own pages. Gelato then expects the file to hold three more: the cover
// sheet, the endpaper and the last page, which is how print.js builds it (a 62-page book is a
// 65-page file). The first draft, sent with pages plus four, was refused for wanting 69.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

const env = (name: string) => Deno.env.get(name)?.trim() ?? ''
const gelato = 'https://order.gelatoapis.com/v4'

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

type Row = Record<string, any>
const cents = (n: unknown) => Math.round(Number(n) * 100)
const answer = (o: Row) => ({
  id: o.id,
  status: o.status,
  quote: o.quote_product_cents == null ? null : {
    productCents: o.quote_product_cents, shippingCents: o.quote_shipping_cents, currency: o.quote_currency,
    method: o.shipment_method_name ?? null, days: o.delivery_days,
  },
  gelatoOrderID: o.gelato_order_id,
  gelatoOrderType: o.gelato_order_type,
  failure: o.failure,
})

// Gelato's errors are JSON; its docs don't pin the shape, so look in the likely places.
const why = (body: any, status: number) =>
  String(body?.message ?? body?.error?.message ?? body?.error ?? `the printer answered ${status}`).slice(0, 500)

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405)

  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? ''
  const { data: who } = await supabase.auth.getUser(token)
  const user = who?.user
  if (!user) return json({ error: 'sign in to order' }, 401)

  const { action, orderID } = await req.json().catch(() => ({}))
  if (!['quote', 'place'].includes(action) || typeof orderID !== 'string') return json({ error: 'quote or place which order?' }, 400)

  const { data: order, error } = await supabase.from('book_orders').select().eq('id', orderID).eq('user_id', user.id).maybeSingle()
  if (error) return json({ error: 'could not read the order' }, 500)
  if (!order) return json({ error: 'no such order' }, 404)
  if (!order.print_path || !order.ship_line1) return json({ ...answer(order), error: 'this order has no print file or address' }, 409)
  if (!user.email) return json({ ...answer(order), error: 'the printer needs an email address on your account' }, 409)

  const key = env('GELATO_API_KEY'), product = env('GELATO_PHOTOBOOK_UID')
  if (!key || !product) return json({ ...answer(order), error: 'printing is not set up yet' }, 503)

  const recipient = {
    firstName: order.ship_first_name, lastName: order.ship_last_name,
    addressLine1: order.ship_line1, ...(order.ship_line2 ? { addressLine2: order.ship_line2 } : {}),
    city: order.ship_city, state: order.ship_state, postCode: order.ship_zip, country: order.ship_country,
    email: user.email,
  }
  const { data: signed } = await supabase.storage.from('prints').createSignedUrl(order.print_path, 60 * 60 * 24)
  if (!signed?.signedUrl) return json({ ...answer(order), error: 'the print file is missing' }, 409)
  const item = {
    itemReferenceId: order.id, productUid: product, quantity: order.quantity,
    pageCount: order.page_count, files: [{ type: 'default', url: signed.signedUrl }],
  }
  const call = (path: string, body: unknown) => fetch(`${gelato}${path}`, {
    method: 'POST', headers: { 'X-API-KEY': key, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  })
  const save = async (patch: Row) =>
    (await supabase.from('book_orders').update(patch).eq('id', order.id).select().single()).data ?? { ...order, ...patch }

  if (action === 'quote') {
    if (!['requested', 'failed'].includes(order.status)) return json(answer(order))
    const res = await call('/orders:quote', {
      orderReferenceId: order.id, customerReferenceId: user.id, currency: 'USD', recipient, products: [item],
    })
    const body = await res.json().catch(() => ({}))
    if (!res.ok || !Array.isArray(body?.quotes) || !body.quotes.length) {
      console.error('book-order: quote', res.status, JSON.stringify(body).slice(0, 1000))
      return json({ ...answer(order), error: why(body, res.status) }, res.ok ? 502 : 422)
    }
    // Gelato may split an order across facilities; each part has its products and shipping options.
    let product_ = 0, shipping = 0, currency = 'USD', min = Infinity, max = 0
    const methods: string[] = [], names: string[] = []
    for (const q of body.quotes) {
      product_ += (q.products ?? []).reduce((sum: number, p: Row) => sum + cents(p.price), 0)
      const cheapest = [...(q.shipmentMethods ?? [])].sort((a: Row, b: Row) => a.price - b.price)[0]
      if (!cheapest) return json({ ...answer(order), error: 'the printer has no way to ship to that address' }, 422)
      shipping += cents(cheapest.price)
      currency = cheapest.currency ?? q.products?.[0]?.currency ?? currency
      methods.push(cheapest.shipmentMethodUid); names.push(cheapest.name)
      min = Math.min(min, cheapest.minDeliveryDays ?? Infinity); max = Math.max(max, cheapest.maxDeliveryDays ?? 0)
    }
    const saved = await save({
      quote_product_cents: product_, quote_shipping_cents: shipping, quote_currency: currency,
      shipment_method: methods.join(','), shipment_method_name: names.join(', '),
      delivery_days: Number.isFinite(min) && max ? (min === max ? `${min}` : `${min}–${max}`) : null,
      status: 'requested', failure: null,
    })
    return json(answer(saved))
  }

  // place
  if (order.gelato_order_id) return json(answer(order))
  if (!['requested', 'paid'].includes(order.status)) return json({ ...answer(order), error: 'this order can\'t be sent' }, 409)
  if (order.quote_product_cents == null) return json({ ...answer(order), error: 'get a price first' }, 409)
  const real = order.status === 'paid'
  const res = await call('/orders', {
    orderType: real ? 'order' : 'draft',
    orderReferenceId: order.id,
    customerReferenceId: user.id,
    currency: order.quote_currency ?? 'USD',
    items: [item],
    shippingAddress: recipient,
    ...(order.shipment_method ? { shipmentMethodUid: order.shipment_method } : {}),
    metadata: [{ key: 'book_id', value: String(order.book_id ?? '') }, { key: 'book_revision', value: String(order.book_revision) }],
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok || !body?.id) {
    console.error('book-order: place', res.status, JSON.stringify(body).slice(0, 1000))
    const failed = await save({ status: 'failed', failure: why(body, res.status) })
    return json({ ...answer(failed), error: failed.failure }, res.ok ? 502 : 422)
  }
  const placed = await save({
    status: real ? 'printing' : 'draft', gelato_order_id: body.id, gelato_order_type: body.orderType ?? (real ? 'order' : 'draft'),
    sent_at: new Date().toISOString(), failure: null,
  })
  return json(answer(placed))
})

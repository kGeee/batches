// Gelato's cover measurements for a photo book with a given number of pages, so the web viewer can
// draw the cover sheet (back, hinges, spine, front and the wrap round the boards) at exactly the
// size Gelato prints. The browser calls this signed in; the API key never leaves the server.
//
// Secrets (supabase secrets set ...):
//   GELATO_API_KEY         a Gelato API key (API Portal > Developer > API Keys)
//   GELATO_PHOTOBOOK_UID   the product UID of the 8x8 in hardcover photo book, from Gelato's
//                          photo book catalog (products:search)
// Without them it answers 503 and the viewer falls back to an estimated cover.
//
// Gelato's docs describe pageCount as counting the covers, but their example answer calls the same
// number inner pages. We send the book's own page count; check it against a draft order before
// printing for real.

const env = (name: string) => Deno.env.get(name)?.trim() ?? ''

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405)

  const key = env('GELATO_API_KEY')
  const product = env('GELATO_PHOTOBOOK_UID')
  if (!key || !product) return json({ dimensions: null, error: 'printing is not set up' }, 503)

  const { pages } = await req.json().catch(() => ({ pages: null }))
  if (!Number.isInteger(pages) || pages < 30 || pages > 200 || pages % 2) {
    return json({ error: 'pages must be an even number from 30 to 200' }, 400)
  }

  const url = `https://product.gelatoapis.com/v3/products/${encodeURIComponent(product)}/cover-dimensions?pageCount=${pages}`
  const res = await fetch(url, { headers: { 'X-API-KEY': key } })
  if (!res.ok) {
    console.error('print-cover: Gelato answered', res.status, await res.text().catch(() => ''))
    return json({ dimensions: null, error: 'the printer did not answer' }, 502)
  }
  return json({ dimensions: await res.json() })
})

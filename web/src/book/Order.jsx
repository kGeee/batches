// Checking a book over, making its print files, and asking for it to be printed.
import { useEffect, useMemo, useState } from 'react'
import * as api from '../api.js'
import { counted, go, longDate } from '../ui.jsx'
import { money, priceCents } from './format.js'
import { preflight } from './preflight.js'
const statusTitle = { requested: 'Requested', paid: 'Paid', printing: 'Printing', shipped: 'Shipped', cancelled: 'Cancelled' }

export function OrderView({ bag }) {
  const { id, doc, photos, batches, me, format, save, revision, setFocus } = bag
  const check = useMemo(() => preflight(doc, photos), [doc, photos])
  const [quantity, setQuantity] = useState(1)
  const [files, setFiles] = useState(null)        // { revision, path, url, pages, size, estimated }
  const [progress, setProgress] = useState(null)  // { done, total, step }
  const [problem, setProblem] = useState('')
  const [orders, setOrders] = useState([])
  const [ordered, setOrdered] = useState(false)
  useEffect(() => { api.ordersOf(id).then(setOrders).catch(() => {}) }, [id, ordered])
  useEffect(() => () => { if (files) URL.revokeObjectURL(files.url) }, [files])

  const stale = files && (files.revision !== revision.current || save !== 'saved')
  const each = priceCents(format, doc.pages.length)
  const sorted = [...check.problems].sort((a, b) => (a.level === b.level ? (a.page ?? -1) - (b.page ?? -1) : a.level === 'block' ? -1 : 1))

  const make = async () => {
    setProblem('')
    const snapshot = doc, rev = revision.current
    try {
      setProgress({ done: 0, total: 1, step: 'cover' })
      const [{ bookPDF }, printer] = await Promise.all([import('./print.js'), api.coverDimensions(snapshot.pages.length)])
      const { blob, sheet } = await bookPDF(snapshot, { photos, batches, me }, {
        printer, onProgress: (step, done, total) => setProgress({ step, done, total }),
      })
      setProgress({ done: 0, total: 1, step: 'upload' })
      const path = `${me}/${id}/${rev}/book.pdf`
      await api.uploadPrint(path, blob)
      setFiles({ revision: rev, path, pages: snapshot.pages.length, url: URL.createObjectURL(blob), size: blob.size, estimated: sheet.estimate })
    } catch (e) {
      setProblem(e.message ?? String(e))
    } finally { setProgress(null) }
  }

  const order = async () => {
    setProblem('')
    try {
      await api.orderBook({ bookID: id, revision: files.revision, quantity, printPath: files.path, pageCount: files.pages })
      setOrdered(true)
    } catch (e) { setProblem(e.message) }
  }

  return (
    <div className="orderview">
      <section className="card">
        <h2 className="title">Checks</h2>
        {!sorted.length && <p className="lede" style={{ marginTop: 8 }}>Everything looks ready to print.</p>}
        {sorted.length > 0 && (
          <ul className="problems" style={{ marginTop: 10 }}>
            {sorted.map((p, i) => (
              <li key={i} className={p.level}>
                <i className="dot" aria-label={p.level === 'block' ? 'Must fix' : 'Worth a look'} />
                <span>{p.page !== null ? <b>Page {p.page + 1}: </b> : null}{p.text}</span>
                {p.page !== null && <button className="secondary" onClick={() => { setFocus({ page: doc.pages[p.page].id, item: p.item }); go(`/app/books/${id}`) }}>Show</button>}
                {p.page === null && /cover/i.test(p.text) && <button className="secondary" onClick={() => go(`/app/books/${id}/cover`)}>Cover</button>}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="card">
        <h2 className="title">Your book</h2>
        <div className="summary" style={{ marginTop: 10 }}>
          <span>{format.title} · {format.detail}</span><span />
          <span>{counted(doc.pages.length, 'page')}</span><span>{money(each)} each</span>
          <span>Copies</span>
          <span className="qty">
            <button className="round" onClick={() => setQuantity(Math.max(1, quantity - 1))} disabled={quantity <= 1} aria-label="Fewer">−</button>
            <b>{quantity}</b>
            <button className="round" onClick={() => setQuantity(Math.min(20, quantity + 1))} disabled={quantity >= 20} aria-label="More">+</button>
          </span>
          <span>Shipping</span><span>{money(format.shippingCents)}</span>
          <span className="total">Total</span><span className="total">{money(each * quantity + format.shippingCents)}</span>
        </div>
      </section>

      <section className="card stacked">
        <h2 className="title">Print file</h2>
        <p className="meta">One PDF for the printer: the cover, then every page drawn at 300 dpi from the largest copies shared with you, with 3 mm of bleed.</p>
        {progress && (
          <>
            <div className="progress"><span style={{ width: `${(progress.done / progress.total) * 100}%` }} /></div>
            <p className="meta">{progress.step === 'pages' ? `Drawing page ${Math.min(progress.total, progress.done + 1)} of ${progress.total}…` : progress.step === 'cover' ? 'Drawing the cover…' : 'Uploading…'}</p>
          </>
        )}
        {!progress && (!files || stale) && (
          <button className="primary" disabled={check.blocked || save !== 'saved'} onClick={make} style={{ justifySelf: 'start' }}>
            {stale ? 'Make it again' : 'Make print file'}
          </button>
        )}
        {check.blocked && <p className="meta">Fix the checks marked red first.</p>}
        {save !== 'saved' && !check.blocked && <p className="meta">Waiting for your changes to save…</p>}
        {files && !progress && (
          <div className="filelinks">
            <a className="button secondary small" href={files.url} download={`${doc.title}.pdf`}>Book PDF</a>
            <span className="meta" style={{ alignSelf: 'center' }}>{(files.size / 1048576).toFixed(1)} MB{stale ? ' · out of date, the book has changed' : ''}</span>
          </div>
        )}
        {files && !progress && files.estimated && <p className="meta">The cover is sized from an estimate until printing is connected, so its spine and wrap may change.</p>}
        {problem && <p className="problem">{problem}</p>}
      </section>

      <section className="card stacked">
        <h2 className="title">Order</h2>
        {ordered ? (
          <p className="lede">Requested. Paying and shipping details come next; we'll email you when your copy is ready to pay for.</p>
        ) : (
          <>
            <p className="meta">Printing isn't open to everyone yet. Requesting saves this exact file with your order.</p>
            <button className="primary" disabled={!files || stale || !!progress} onClick={order} style={{ justifySelf: 'start' }}>
              Request {counted(quantity, 'copy', 'copies')} · {money(each * quantity + format.shippingCents)}
            </button>
          </>
        )}
        {orders.length > 0 && (
          <ul className="problems">
            {orders.map((o) => (
              <li key={o.id}><span>{longDate(o.created_at)} · {counted(o.quantity, 'copy', 'copies')} · {counted(o.page_count, 'page')}</span><b>{statusTitle[o.status] ?? o.status}</b></li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}

// Every page at once, for ordering spreads and chapters, and the cover.
import { useEffect, useMemo, useState } from 'react'
import * as api from '../api.js'
import { fontFamily } from '../look.js'
import { Icon, Sheet, Spinner, counted, go } from '../ui.jsx'
import {
  addChapter, addSpread, bookFonts, chapterPageIndices, cloths, moveChapter, moveSpread, personName,
  relayoutChapter, removeChapter, removeSpread, renameChapter, setCover, setCredits,
} from './doc.js'
import { spreadIndexOf, spreadsOf } from './format.js'
import { BookCover, BookSpread } from './render.jsx'
import { PhotoGrid } from './Editor.jsx'
import { PickableBatch } from './Books.jsx'

export function PagesView({ bag }) {
  const { id, doc, apply, batches, me, format, setSpread } = bag
  const [dragging, setDragging] = useState(null)
  const [over, setOver] = useState(null)
  const [adding, setAdding] = useState(false)
  const spreads = spreadsOf(doc.pages.map((_, i) => i))
  const movable = (n) => n > 0 && n < spreads.length - 1
  const open = (n) => { setSpread(n); go(`/app/books/${id}`) }

  const chapterStarts = useMemo(() => {
    const starts = new Map()
    doc.chapters.forEach((c) => {
      const first = doc.pages.findIndex((p) => p.chapter === c.id)
      if (first < 0) return
      const n = spreadIndexOf(first)
      starts.set(n, [...(starts.get(n) ?? []), c])
    })
    return starts
  }, [doc])

  return (
    <div className="pagesview">
      <section className="settingsrow">
        <label><span className="label">Under the title</span>
          <input type="text" value={doc.byline} maxLength={120} onChange={(e) => apply((d) => ({ ...d, byline: e.target.value }), 'byline')} placeholder="Your name, or who's in it" />
        </label>
        <label className="checkline" style={{ flex: '0 1 auto' }}>
          <input type="checkbox" checked={doc.credits} onChange={(e) => apply((d) => setCredits(d, e.target.checked))} />
          Credit friends under the photos they took
        </label>
        <span className="meta">{counted(doc.pages.length, 'page')} · {format.minPages}–{format.maxPages}</span>
      </section>

      <section className="chapterblock" aria-label="Chapters">
        <div className="chapterhead"><h2 className="title">Chapters</h2><span className="spacer" />
          <button className="secondary small" onClick={() => setAdding(true)}><Icon name="plus" size={16} />Add a batch</button>
        </div>
        {!doc.chapters.length && <p className="meta">No chapters. Add a batch to bring in its photos.</p>}
        {doc.chapters.map((c, i) => {
          const b = batches[c.batch]
          const pages = chapterPageIndices(doc, c.id)
          return (
            <div className="chapterhead" key={c.id}>
              <span className="meta" style={{ width: '2.5ch' }}>{i + 1}</span>
              <input aria-label="Chapter title" value={c.title} style={{ fontFamily: fontFamily(c.font) }} maxLength={120}
                     onChange={(e) => apply((d) => renameChapter(d, c.id, e.target.value), `chapter:${c.id}`)} />
              <span className="meta">{b && b.owner_id !== me ? `${personName(b.owner)} · ` : ''}{pages.length ? counted(pages.length, 'page') : 'by date'}</span>
              <button className="round" disabled={i === 0} onClick={() => apply((d) => moveChapter(d, c.id, -1))} aria-label="Move chapter earlier"><Icon name="up" size={16} /></button>
              <button className="round" disabled={i === doc.chapters.length - 1} onClick={() => apply((d) => moveChapter(d, c.id, 1))} aria-label="Move chapter later"><Icon name="down" size={16} /></button>
              <button className="secondary small" disabled={!b || !pages.length} onClick={() => {
                if (window.confirm(`Lay out “${c.title}” again from its batch? Changes to its pages will be replaced. You can undo this.`)) apply((d) => relayoutChapter(d, c.id, b, format))
              }}>Lay out again</button>
              <button className="round" onClick={() => {
                if (window.confirm(`Take “${c.title}” and its pages out of the book? You can undo this.`)) apply((d) => removeChapter(d, c.id, format))
              }} aria-label="Remove chapter"><Icon name="trash" size={16} /></button>
            </div>
          )
        })}
      </section>

      <section className="chapterblock" aria-label="Spreads">
        <div className="chapterhead"><h2 className="title">Spreads</h2><span className="meta">Drag to reorder. Click to edit.</span></div>
        <div className="spreadgrid">
          {spreads.map(([l, r], n) => (
            <div key={n} style={{ display: 'contents' }}>
              {chapterStarts.get(n)?.map((c) => <h3 key={c.id} className="section-title" style={{ gridColumn: '1 / -1', margin: '8px 0 0', fontFamily: fontFamily(c.font) }}>{c.title}</h3>)}
              <div className={`spreadcard ${dragging === n ? 'dragging' : ''} ${over === n && dragging !== n ? 'over' : ''}`}
                   draggable={movable(n)} onClick={() => open(n)} role="button" tabIndex={0} onKeyDown={(e) => { if (e.key === 'Enter') open(n) }}
                   onDragStart={(e) => { setDragging(n); e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', String(n)) }}
                   onDragEnd={() => { setDragging(null); setOver(null) }}
                   onDragOver={(e) => { if (dragging !== null && movable(n)) { e.preventDefault(); setOver(n) } }}
                   onDrop={(e) => { e.preventDefault(); if (dragging !== null && movable(n)) apply((d) => moveSpread(d, dragging, n)); setDragging(null); setOver(null) }}>
                <BookSpread doc={doc} spread={n} />
                <div className="meta">
                  <span>{l === null ? 'Page 1' : r === null ? `Page ${l + 1}` : `Pages ${l + 1}–${r + 1}`}</span>
                  <span>
                    <button onClick={(e) => { e.stopPropagation(); apply((d) => addSpread(d, r ?? l ?? 0, format)) }} disabled={doc.pages.length + 2 > format.maxPages}>+ 2 pages</button>
                    {movable(n) && <button onClick={(e) => { e.stopPropagation(); apply((d) => removeSpread(d, n, format)) }} disabled={doc.pages.length - 2 < format.minPages}>Remove</button>}
                  </span>
                </div>
              </div>
            </div>
          ))}
        </div>
      </section>
      {adding && <AddBatchSheet bag={bag} onClose={() => setAdding(false)} />}
    </div>
  )
}

function AddBatchSheet({ bag, onClose }) {
  const { doc, apply, me, ctx, format, addBatch } = bag
  const [list, setList] = useState(undefined)
  const [keepLook, setKeepLook] = useState(true)
  useEffect(() => {
    Promise.all([api.batchesOf(me), api.feed(me).catch(() => [])]).then(([mine, theirs]) => {
      const inBook = new Set(doc.chapters.map((c) => c.batch))
      setList([...mine, ...theirs.filter((b) => !ctx.blocked.has(b.owner_id))].filter((b) => b.photos.length && !inBook.has(b.id)))
    }).catch(() => setList([]))
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <Sheet title="Add a batch" onClose={onClose}>
      <p className="sheet-text">It becomes a new chapter at the end, laid out for you.</p>
      <label className="checkline"><input type="checkbox" checked={keepLook} onChange={(e) => setKeepLook(e.target.checked)} /> Keep its frames, colours and font</label>
      {list === undefined && <Spinner />}
      {list && !list.length && <p className="meta">Every batch you can use is already in the book.</p>}
      <div className="grid inner">
        {list?.map((b) => (
          <PickableBatch key={b.id} batch={b} showOwner={b.owner_id !== me} on={false} onToggle={() => {
            addBatch(b)
            apply((d) => addChapter(d, b, keepLook, me, format))
            onClose()
          }} />
        ))}
      </div>
    </Sheet>
  )
}

export function CoverView({ bag }) {
  const { doc, apply } = bag
  return (
    <div className="coverview">
      <BookCover doc={doc} />
      <aside className="coverpanel">
        <label className="label" htmlFor="cover-title">Title on the cover</label>
        <input id="cover-title" value={doc.cover.title} maxLength={120} onChange={(e) => apply((d) => setCover(d, { title: e.target.value }), 'cover-title')} />
        <label className="label" htmlFor="cover-byline">Under it</label>
        <input id="cover-byline" value={doc.byline} maxLength={120} onChange={(e) => apply((d) => ({ ...d, byline: e.target.value }), 'byline')} />
        <label className="label" htmlFor="cover-font">Lettering</label>
        <select id="cover-font" value={doc.cover.font} onChange={(e) => apply((d) => setCover(d, { font: e.target.value }))}>
          {bookFonts.map((f) => <option key={f} value={f}>{f[0].toUpperCase() + f.slice(1)}</option>)}
        </select>
        <span className="label">Cloth</span>
        <div className="swatches" role="radiogroup" aria-label="Cloth" style={{ marginBottom: 12 }}>
          {Object.entries(cloths).map(([k, v]) => (
            <button key={k} role="radio" aria-checked={doc.cover.cloth === k} title={v.title} className={`swatch ${doc.cover.cloth === k ? 'on' : ''}`}
                    style={{ background: v.color, width: 38, height: 38 }} onClick={() => apply((d) => setCover(d, { cloth: k }))} />
          ))}
        </div>
        <span className="label">Cover photo</span>
        <PhotoGrid bag={bag} chosen={doc.cover.photo} onPick={(p) => apply((d) => setCover(d, { photo: p.id }))} />
      </aside>
    </div>
  )
}

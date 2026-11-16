// The book editor: a spread at a time, photos from the book's batches in a tray beside it.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Icon, Photo, Sheet } from '../ui.jsx'
import { fontFamily } from '../look.js'
import { frameKinds, frameTitles, isLeftPage, printBox, spreadIndexOf, spreadsOf } from './format.js'
import {
  addPhoto, addText, applyLayout, backgrounds, bookFonts, bringToFront, chapterOf, layoutChoices, pageIndex, pageOf,
  personName, removeItem, setBackground, setFrame, swapPhoto, updateItem, usedPhotoIDs,
} from './doc.js'
import { BookPage, BookSpread } from './render.jsx'

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
const photoType = 'application/x-batches-photo'
const typing = (el) => el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable)

/** Dragging items: move, resize from a corner, or turn. One gesture is one undo step. */
function useGestures(apply) {
  return useCallback((e, { pageID, item, mode, left }) => {
    if (e.button !== 0) return
    e.preventDefault()
    e.stopPropagation()
    const pageEl = e.currentTarget.closest('.bpage')
    const itemEl = e.currentTarget.closest('.bitem')
    if (!pageEl || !itemEl) return
    const unit = pageEl.getBoundingClientRect().width
    const ir = itemEl.getBoundingClientRect()
    const cx = ir.left + ir.width / 2, cy = ir.top + ir.height / 2
    const sx = e.clientX, sy = e.clientY
    const key = `${mode}:${item.id}:${performance.now()}`
    let moved = false
    const move = (ev) => {
      if (!moved && Math.hypot(ev.clientX - sx, ev.clientY - sy) < 3) return
      moved = true
      let patch
      if (mode === 'move') {
        patch = { x: clamp(item.x + (ev.clientX - sx) / unit, -0.4, left ? 2.4 : 1.4), y: clamp(item.y + (ev.clientY - sy) / unit, -0.4, 1.4) }
      } else if (mode === 'turn') {
        const a = Math.atan2(ev.clientY - cy, ev.clientX - cx) - Math.atan2(sy - cy, sx - cx)
        let r = item.rotation + (a * 180) / Math.PI
        r = ((r + 540) % 360) - 180
        patch = { rotation: Math.abs(r) < 2 ? 0 : clamp(Math.round(r), -45, 45) }
      } else {
        const f = Math.hypot(ev.clientX - cx, ev.clientY - cy) / Math.max(4, Math.hypot(sx - cx, sy - cy))
        patch = item.kind === 'photo' ? { w: clamp(item.w * f, 0.06, 2) } : { size: clamp(item.size * f, 0.012, 0.25) }
      }
      apply((d) => updateItem(d, pageID, item.id, patch, { free: item.kind === 'photo' }), key)
    }
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up) }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }, [apply])
}

export function Editor({ bag }) {
  const { doc, apply, undo, redo, photos, batches, me, format, spread, setSpread, focus, setFocus } = bag
  const [sel, setSel] = useState({ page: null, items: [] })
  const [active, setActive] = useState(null)
  const [swapping, setSwapping] = useState(false)
  const [layoutFor, setLayoutFor] = useState(null)
  const [editing, setEditing] = useState(null)
  const [dropOn, setDropOn] = useState(null)
  const gesture = useGestures(apply)

  const spreads = useMemo(() => spreadsOf(doc.pages.map((_, i) => i)), [doc.pages])
  const s = clamp(spread, 0, spreads.length - 1)
  const [li, ri] = spreads[s]
  const onSpread = [li, ri].filter((i) => i !== null).map((i) => doc.pages[i].id)
  const activeID = onSpread.includes(active) ? active : onSpread.includes(sel.page) ? sel.page : doc.pages[ri ?? li].id

  // Arriving from the order checks with something to look at.
  useEffect(() => {
    if (!focus) return
    const i = pageIndex(doc, focus.page)
    if (i >= 0) { setSpread(spreadIndexOf(i)); setActive(focus.page); setSel({ page: focus.page, items: focus.item ? [focus.item] : [] }) }
    setFocus(null)
  }, [focus]) // eslint-disable-line react-hooks/exhaustive-deps

  const go = (n) => { setSpread(clamp(n, 0, spreads.length - 1)); setSel({ page: null, items: [] }); setSwapping(false) }

  const selectedItems = sel.page ? (pageOf(doc, sel.page)?.items ?? []).filter((i) => sel.items.includes(i.id)) : []
  const removeSelected = useCallback(() => {
    if (!sel.page || !sel.items.length) return
    apply((d) => sel.items.reduce((acc, id) => removeItem(acc, sel.page, id, photos, format), d))
    setSel({ page: sel.page, items: [] })
  }, [sel, apply, photos, format])

  useEffect(() => {
    const key = (e) => {
      if (typing(document.activeElement)) return
      const mod = e.metaKey || e.ctrlKey
      if (mod && e.key.toLowerCase() === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); return }
      if (mod && e.key.toLowerCase() === 'y') { e.preventDefault(); redo(); return }
      if (document.querySelector('.sheet-bg, .preview')) return
      if ((e.key === 'Delete' || e.key === 'Backspace') && sel.items.length) { e.preventDefault(); removeSelected(); return }
      if (e.key === 'Escape') { setSel({ page: null, items: [] }); setSwapping(false); return }
      if (e.key.startsWith('Arrow') && sel.items.length) {
        e.preventDefault()
        const step = e.shiftKey ? 0.02 : 0.004
        const dx = e.key === 'ArrowLeft' ? -step : e.key === 'ArrowRight' ? step : 0
        const dy = e.key === 'ArrowUp' ? -step : e.key === 'ArrowDown' ? step : 0
        apply((d) => sel.items.reduce((acc, id) => {
          const it = pageOf(acc, sel.page).items.find((x) => x.id === id)
          return updateItem(acc, sel.page, id, { x: it.x + dx, y: it.y + dy }, { free: it.kind === 'photo' })
        }, d), `nudge:${sel.items.join()}`)
        return
      }
      if (!editing && (e.key === 'ArrowLeft' || e.key === 'PageUp')) { e.preventDefault(); go(s - 1) }
      if (!editing && (e.key === 'ArrowRight' || e.key === 'PageDown')) { e.preventDefault(); go(s + 1) }
    }
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  }) // a fresh closure each render, so keys always see the current selection

  const pageProps = (index, { handles = false } = {}) => {
    const page = doc.pages[index]
    return {
      selected: sel.page === page.id ? sel.items : [],
      handles,
      className: dropOn === page.id ? 'dropping' : '',
      onPageDown: (e) => { if (e.target.closest('.bitem')) return; setActive(page.id); setSel({ page: null, items: [] }) },
      onItemDown: (e, item) => {
        setActive(page.id)
        if (e.shiftKey && sel.page === page.id) {
          setSel({ page: page.id, items: sel.items.includes(item.id) ? sel.items.filter((x) => x !== item.id) : [...sel.items, item.id] })
          return
        }
        if (!(sel.page === page.id && sel.items.includes(item.id))) setSel({ page: page.id, items: [item.id] })
        gesture(e, { pageID: page.id, item, mode: 'move', left: isLeftPage(index) })
      },
      onHandleDown: (e, item, corner) => gesture(e, { pageID: page.id, item, mode: corner === 'turn' ? 'turn' : 'size', left: isLeftPage(index) }),
      onDragOver: (e) => { if (e.dataTransfer.types.includes(photoType)) { e.preventDefault(); setDropOn(page.id) } },
      onDrop: (e) => {
        const id = e.dataTransfer.getData(photoType)
        setDropOn(null)
        if (!id || !photos[id]) return
        e.preventDefault()
        const r = e.currentTarget.getBoundingClientRect()
        apply((d) => addPhoto(d, page.id, photos[id], photos, format, { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.width }))
        setActive(page.id)
      },
    }
  }

  const pick = (photo) => {
    if (swapping && selectedItems[0]?.kind === 'photo') {
      apply((d) => swapPhoto(d, sel.page, selectedItems[0].id, photo, photos, format))
      setSwapping(false)
      return
    }
    apply((d) => addPhoto(d, activeID, photo, photos, format))
  }

  const chaptersWithPages = doc.chapters.map((c) => ({ c, first: doc.pages.findIndex((p) => p.chapter === c.id) })).filter((x) => x.first >= 0)
  const current = doc.pages[ri ?? li]?.chapter ?? doc.pages[li ?? ri]?.chapter
  const label = (i) => (i === null ? 'Inside cover' : `Page ${i + 1}`)

  return (
    <div className="editor" onDragEnd={() => setDropOn(null)} onDragLeave={(e) => { if (!e.currentTarget.contains(e.relatedTarget)) setDropOn(null) }}>
      <section className="stage">
        <nav className="chaptertabs" aria-label="Chapters">
          <button className={s === 0 ? 'on' : ''} onClick={() => go(0)}>Title</button>
          {chaptersWithPages.map(({ c, first }) => (
            <button key={c.id} className={current === c.id ? 'on' : ''} onClick={() => go(spreadIndexOf(first))} style={{ fontFamily: fontFamily(c.font) }}>{c.title || 'Untitled'}</button>
          ))}
        </nav>
        <div className="spreadarea">
          <div>
            <BookSpread doc={doc} spread={s} pageProps={(i) => pageProps(i, { handles: true })} />
            <div className="pagelabels"><span>{label(li)}</span><span>{ri === null ? 'Inside cover' : label(ri)}</span></div>
          </div>
          <button className="round spreadnav prev" disabled={s === 0} onClick={() => go(s - 1)} aria-label="Previous spread"><Icon name="back" /></button>
          <button className="round spreadnav next" disabled={s === spreads.length - 1} onClick={() => go(s + 1)} aria-label="Next spread"><Icon name="forward" /></button>
        </div>
        <Tools bag={bag} pageID={sel.items.length ? sel.page : activeID} items={selectedItems} swapping={swapping} setSwapping={setSwapping}
               onLayout={setLayoutFor} onEdit={setEditing} onRemove={removeSelected} onSelect={(page, items) => setSel({ page, items })} />
        <div className="strip" role="list" aria-label="Spreads">
          {spreads.map((_, n) => (
            <button key={n} role="listitem" className={`strip-spread ${n === s ? 'on' : ''}`} onClick={() => go(n)} ref={n === s ? (el) => el?.scrollIntoView({ block: 'nearest', inline: 'nearest' }) : undefined}>
              <BookSpread doc={doc} spread={n} />
              <span className="meta">{n === 0 ? '1' : n === spreads.length - 1 && spreads[n][1] === null ? String(spreads[n][0] + 1) : `${spreads[n][0] + 1}–${spreads[n][1] + 1}`}</span>
            </button>
          ))}
        </div>
      </section>
      <Tray doc={doc} batches={batches} photos={photos} me={me} swapping={swapping} onPick={pick} activePage={pageIndex(doc, activeID)} />
      {layoutFor && <LayoutSheet bag={bag} pageID={layoutFor} onClose={() => setLayoutFor(null)} />}
      {editing && (
        <PageEditor bag={bag} pageID={editing} onClose={() => setEditing(null)} pageProps={pageProps} sel={sel} setSel={setSel}
                    swapping={swapping} setSwapping={setSwapping} onLayout={setLayoutFor} onRemove={removeSelected} onPick={pick}
                    onMove={(id) => { setEditing(id); setActive(id); setSel({ page: null, items: [] }); setSpread(spreadIndexOf(pageIndex(doc, id))) }} />
      )}
    </div>
  )
}

/** What can be done with the selection, or with the page when nothing is selected. */
function Tools({ bag, pageID, items, swapping, setSwapping, onLayout, onEdit, onRemove, onSelect, inEditor }) {
  const { doc, apply, photos, format } = bag
  const [wholeChapter, setWholeChapter] = useState(false)
  const page = pageOf(doc, pageID)
  if (!page) return <div className="toolbar" />
  const index = pageIndex(doc, pageID)
  const chapter = chapterOf(doc, page.chapter)
  const one = items.length === 1 ? items[0] : null

  if (one?.kind === 'text') {
    const set = (patch, key) => apply((d) => updateItem(d, pageID, one.id, patch), key)
    return (
      <div className="toolbar">
        <textarea aria-label="Words" value={one.text} onChange={(e) => set({ text: e.target.value.slice(0, 400) }, `text:${one.id}`)} />
        <select aria-label="Font" value={one.font} onChange={(e) => set({ font: e.target.value })}>
          {[...bookFonts, 'mono'].map((f) => <option key={f} value={f}>{f === 'mono' ? 'Mono caps' : f[0].toUpperCase() + f.slice(1)}</option>)}
        </select>
        <button onClick={() => set({ size: Math.max(0.012, one.size / 1.15) }, `size:${one.id}`)} aria-label="Smaller">A−</button>
        <button onClick={() => set({ size: Math.min(0.25, one.size * 1.15) }, `size:${one.id}`)} aria-label="Bigger">A+</button>
        <button className={one.italic ? 'on' : ''} onClick={() => set({ italic: !one.italic })} aria-pressed={one.italic}><i>I</i></button>
        {['ink', 'muted', 'accent'].map((c) => <button key={c} className={one.color === c ? 'on' : ''} onClick={() => set({ color: c })}>{c === 'ink' ? 'Ink' : c === 'muted' ? 'Grey' : 'Amber'}</button>)}
        <span className="sep" />
        <button onClick={onRemove}>Remove</button>
      </div>
    )
  }

  if (items.length && items.every((i) => i.kind === 'photo')) {
    const caption = () => {
      const photo = photos[one.photo]
      const box = printBox(one, one.aspect, one.frame)
      const { doc: next, item } = addText(doc, pageID, photo?.caption || 'Caption', { x: one.x, y: Math.min(0.93, one.y + box.h / 2 + 0.035) })
      apply(updateItem(next, pageID, item.id, { size: 0.026, italic: true }))
      onSelect(pageID, [item.id])
    }
    return (
      <div className="toolbar">
        {one && <button className={swapping ? 'on' : ''} onClick={() => setSwapping(!swapping)}>{swapping ? 'Pick a photo…' : 'Swap'}</button>}
        <select aria-label="Frame" value={one?.frame ?? ''} onChange={(e) => apply((d) => items.reduce((acc, it) => setFrame(acc, pageID, it.id, e.target.value, photos, format), d))}>
          {!one && <option value="">Frame…</option>}
          {frameKinds.map((k) => <option key={k} value={k}>{frameTitles[k]}</option>)}
        </select>
        {one && <button onClick={caption}>Caption</button>}
        {one && <button onClick={() => apply((d) => bringToFront(d, pageID, one.id))}>To front</button>}
        {!inEditor && <button onClick={() => onEdit(pageID)}>Edit page</button>}
        <span className="sep" />
        <button onClick={onRemove}>Remove</button>
      </div>
    )
  }

  return (
    <div className="toolbar">
      <span className="hint">{index === 0 ? 'Title page' : `Page ${index + 1}`}{chapter ? ` · ${chapter.title}` : ''}</span>
      <span className="sep" />
      {page.items.some((i) => i.kind === 'photo') && <button onClick={() => onLayout(pageID)}>Layout</button>}
      <button onClick={() => { const { doc: next, item } = addText(doc, pageID); apply(next); onSelect(pageID, [item.id]) }}>Add words</button>
      {!inEditor && <button onClick={() => onEdit(pageID)}>Edit page</button>}
      <span className="sep" />
      <div className="swatches" role="radiogroup" aria-label="Page colour">
        {Object.entries(backgrounds).map(([k, v]) => (
          <button key={k} role="radio" aria-checked={page.background === k} title={v.title} className={`swatch ${page.background === k ? 'on' : ''}`}
                  style={{ background: v.color }} onClick={() => apply((d) => setBackground(d, pageID, k, wholeChapter))} />
        ))}
        {!backgrounds[page.background] && <span className="swatch on" style={{ background: page.background }} title="The batch's colour" />}
      </div>
      {chapter && <label className="checkline" style={{ margin: 0, fontSize: 13 }}><input type="checkbox" checked={wholeChapter} onChange={(e) => setWholeChapter(e.target.checked)} /> Whole chapter</label>}
    </div>
  )
}

/** Photos from the book's batches, by chapter. Drag onto a page, or tap to add to the current one. */
function Tray({ doc, batches, photos, me, swapping, onPick, activePage }) {
  const used = useMemo(() => {
    const n = new Map()
    for (const p of doc.pages) for (const i of p.items) if (i.kind === 'photo') n.set(i.photo, (n.get(i.photo) ?? 0) + 1)
    return n
  }, [doc.pages])
  const groups = useMemo(() => {
    const seen = new Set()
    const out = []
    for (const c of doc.chapters) {
      const b = batches[c.batch]
      if (!b || seen.has(b.id)) continue
      seen.add(b.id)
      out.push(b)
    }
    return out
  }, [doc.chapters, batches])
  const total = groups.reduce((n, b) => n + b.photos.length, 0)
  const placed = groups.reduce((n, b) => n + b.photos.filter((p) => used.has(p.id)).length, 0)
  return (
    <aside className="tray" aria-label="Photos">
      {swapping ? <p className="tray-note swap">Pick the photo to put in its place.</p>
        : <p className="tray-note">Drag photos onto a page, or tap one to add it to page {activePage + 1}. {placed} of {total} in the book.</p>}
      {groups.map((b) => (
        <div key={b.id}>
          <h3><span style={{ fontFamily: fontFamily(b.font) }}>{b.title}</span><span>{b.owner_id !== me ? personName(b.owner) : ''}</span></h3>
          <div className="traygrid">
            {b.photos.map((p) => (
              <button key={p.id} className={`trayphoto ${used.has(p.id) ? 'used' : ''}`} draggable onClick={() => onPick(p)}
                      onDragStart={(e) => { e.dataTransfer.setData(photoType, p.id); e.dataTransfer.effectAllowed = 'copy' }}
                      aria-label={`${used.has(p.id) ? 'In the book. ' : ''}Add photo${p.caption ? `: ${p.caption}` : ''}`}>
                <Photo photo={p} tier="s" />
                {used.get(p.id) > 1 && <span className="uses">×{used.get(p.id)}</span>}
                {p.adder && p.added_by !== me && p.added_by !== b.owner_id && <span className="by">{personName(p.adder)}</span>}
              </button>
            ))}
          </div>
        </div>
      ))}
      {!groups.length && <p className="meta">None of this book's batches are shared with you any more.</p>}
    </aside>
  )
}

function LayoutSheet({ bag, pageID, onClose }) {
  const { doc, apply, photos, format } = bag
  const index = pageIndex(doc, pageID)
  const choices = useMemo(() => layoutChoices(doc, pageID, photos, format), [doc, pageID, photos, format])
  const page = pageOf(doc, pageID)
  return (
    <Sheet title="Layout" onClose={onClose} className="wide-sheet">
      <p className="sheet-text">Every layout keeps each photo whole. Moving a photo by hand makes the page freehand.</p>
      <div className="layoutgrid">
        {choices.map((c) => {
          const preview = applyLayout(doc, pageID, c, photos)
          return (
            <button key={c.id} className={`layoutchoice ${page.layout === c.id ? 'on' : ''}`} onClick={() => { apply(preview); onClose() }}>
              {c.id === 'spread'
                ? <div className="twopage"><BookPage doc={preview} index={index} /><BookPage doc={preview} index={index + 1} /></div>
                : <BookPage doc={preview} index={index} />}
              {c.title}
            </button>
          )
        })}
      </div>
    </Sheet>
  )
}

function PageEditor({ bag, pageID, onClose, pageProps, sel, setSel, swapping, setSwapping, onLayout, onRemove, onMove, onPick }) {
  const { doc } = bag
  const index = pageIndex(doc, pageID)
  useEffect(() => {
    const key = (e) => { if (e.key === 'Escape' && !sel.items.length && !document.querySelector('.sheet-bg')) onClose() }
    window.addEventListener('keydown', key)
    document.body.classList.add('locked')
    return () => { window.removeEventListener('keydown', key); document.body.classList.remove('locked') }
  }, [sel.items.length, onClose])
  if (index < 0) return null
  const items = sel.page === pageID ? doc.pages[index].items.filter((i) => sel.items.includes(i.id)) : []
  return (
    <div className="pageeditor" role="dialog" aria-modal="true" aria-label={`Page ${index + 1}`}>
      <div className="pageeditor-top">
        <button className="round" disabled={index === 0} onClick={() => onMove(doc.pages[index - 1].id)} aria-label="Previous page"><Icon name="back" /></button>
        <b>Page {index + 1}</b>
        <button className="round" disabled={index === doc.pages.length - 1} onClick={() => onMove(doc.pages[index + 1].id)} aria-label="Next page"><Icon name="forward" /></button>
        <span className="spacer" />
        <span className="meta light">Drag to move · corners to resize · the dot to turn · Shift-click to pick several</span>
        <button className="primary small" onClick={onClose}>Done</button>
      </div>
      <div className="pageeditor-page" onPointerDown={(e) => { if (e.target === e.currentTarget) setSel({ page: null, items: [] }) }}>
        <BookPage doc={doc} index={index} {...pageProps(index, { handles: true })} />
      </div>
      <Tools bag={bag} pageID={pageID} items={items} swapping={swapping} setSwapping={setSwapping} onLayout={onLayout} onRemove={onRemove}
             onSelect={(page, ids) => setSel({ page, items: ids })} inEditor />
      {swapping && (
        <Sheet title="Swap photo" onClose={() => setSwapping(false)}>
          <PhotoGrid bag={bag} onPick={onPick} />
        </Sheet>
      )}
    </div>
  )
}

/** Every photo in the book's batches, for picking one. */
export function PhotoGrid({ bag, onPick, chosen }) {
  const { doc, batches } = bag
  const list = [...new Set(doc.chapters.map((c) => c.batch))].map((id) => batches[id]).filter(Boolean)
  return list.map((b) => (
    <div key={b.id}>
      <h3 className="label" style={{ fontFamily: fontFamily(b.font) }}>{b.title}</h3>
      <div className="traygrid">
        {b.photos.map((p) => (
          <button key={p.id} className={`trayphoto ${chosen === p.id ? 'on' : ''}`} onClick={() => onPick(p)} aria-pressed={chosen === p.id}>
            <Photo photo={p} tier="s" />
          </button>
        ))}
      </div>
    </div>
  ))
}

export { usedPhotoIDs }

// One book: loads it and its batches, keeps the undo history, saves as you go, and shows the
// editor, all pages, the cover, ordering, or a read-through preview.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import * as api from '../api.js'
import { Icon, Link, Menu, Sheet, Spinner, go } from '../ui.jsx'
import { cleanDoc, setTitle } from './doc.js'
import { formatOf, spreadsOf } from './format.js'
import { useHistory } from './history.js'
import { BookContext, BookCover, BookSpread } from './render.jsx'
import { Editor } from './Editor.jsx'
import { CoverView, PagesView } from './Pages.jsx'
import { OrderView } from './Order.jsx'

const saveDelay = 1200
const chapterBatches = (doc) => [...new Set(doc.chapters.map((c) => c.batch).filter(Boolean))]

export function BookScreen({ id, view, ctx }) {
  const me = ctx.me.id
  const [loaded, setLoaded] = useState(undefined)
  const [batchList, setBatchList] = useState([])
  const [error, setError] = useState(null)
  const [save, setSave] = useState('saved')
  const [spread, setSpread] = useState(0)
  const [focus, setFocus] = useState(null)
  const history = useHistory(null)
  const revision = useRef(0)
  const savedDoc = useRef(null)
  const savedBatches = useRef('')
  const saving = useRef(false)

  const load = useCallback(async () => {
    setError(null)
    try {
      const book = await api.book(id)
      if (!book) { setLoaded(null); return }
      const doc = cleanDoc(book.doc)
      const linked = await api.bookBatchIDs(id).catch(() => [])
      const batches = await api.batchesByIDs([...new Set([...chapterBatches(doc), ...linked])])
      revision.current = book.revision
      savedDoc.current = doc
      savedBatches.current = linked.join()
      history.reset(doc)
      setBatchList(batches)
      setLoaded(book)
      setSave('saved')
    } catch (e) { setError(e) }
  }, [id]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [load])

  const doc = history.doc
  const saveNow = useCallback(async () => {
    const current = history.current()
    if (!current || current === savedDoc.current || saving.current) return
    saving.current = true
    setSave('saving')
    try {
      revision.current = await api.saveBook(id, { title: current.title.trim() || 'Untitled book', doc: current }, revision.current)
      savedDoc.current = current
      const ids = chapterBatches(current)
      if (ids.join() !== savedBatches.current) { await api.setBookBatches(id, ids); savedBatches.current = ids.join() }
      setSave(history.current() === current ? 'saved' : 'unsaved')
    } catch (e) {
      setSave(e instanceof api.BookConflict ? 'conflict' : 'error')
      saving.current = false
      return
    }
    saving.current = false
    if (history.current() !== savedDoc.current) setTimeout(saveNow, 300)
  }, [id]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!doc || doc === savedDoc.current || save === 'conflict') return
    setSave((s) => (s === 'saving' ? s : 'unsaved'))
    const t = setTimeout(saveNow, saveDelay)
    return () => clearTimeout(t)
  }, [doc]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (save === 'saved') return
    const warn = (e) => { e.preventDefault(); e.returnValue = '' }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [save])

  const batches = useMemo(() => Object.fromEntries(batchList.map((b) => [b.id, b])), [batchList])
  const photos = useMemo(() => Object.fromEntries(batchList.flatMap((b) => b.photos.map((p) => [p.id, p]))), [batchList])
  const context = useMemo(() => ({ photos, batches, me }), [photos, batches, me])
  const addBatch = useCallback((b) => setBatchList((list) => (list.some((x) => x.id === b.id) ? list : [...list, b])), [])

  if (error) return <main><p className="problem">{error.message}</p><button className="secondary" onClick={load}>Try again</button></main>
  if (loaded === undefined || (loaded && !doc)) return <Spinner />
  if (loaded === null) {
    return <main><div className="card empty"><h2 className="title">This book isn't here</h2><p>It may have been deleted.</p><Link className="button primary" to="/app/books">Your books</Link></div></main>
  }

  const format = formatOf(doc)
  const bag = {
    id, doc, apply: history.apply, undo: history.undo, redo: history.redo, photos, batches, addBatch, me, ctx, format,
    spread, setSpread, focus, setFocus, revision, saveNow, save, book: loaded,
  }
  const tab = (v, label) => (
    <Link to={`/app/books/${id}${v === 'edit' ? '' : `/${v}`}`} className={view === v ? 'on' : ''} aria-current={view === v ? 'page' : undefined}>{label}</Link>
  )
  const saveText = { saved: 'Saved', unsaved: 'Edited', saving: 'Saving…', error: 'Couldn\'t save', conflict: 'Changed elsewhere' }[save]

  return (
    <BookContext.Provider value={context}>
      <div className="bookapp">
        <header className="bookbar">
          <Link className="round" to="/app/books" aria-label="Your books"><Icon name="back" /></Link>
          <input className="booktitle" aria-label="Book title" value={doc.title} maxLength={120}
                 onChange={(e) => history.apply((d) => setTitle(d, e.target.value), 'title')} />
          <span className={`savestate ${save === 'error' || save === 'conflict' ? 'problem' : ''}`} role="status">
            {saveText}{save === 'error' && <> · <button className="link" onClick={saveNow}>Retry</button></>}
          </span>
          <nav className="booktabs" aria-label="Book">
            {tab('edit', 'Spreads')}{tab('pages', 'Pages')}{tab('cover', 'Cover')}{tab('order', 'Order')}
          </nav>
          <button className="round" onClick={history.undo} disabled={!history.canUndo} aria-label="Undo" title="Undo (⌘Z)"><Icon name="undo" size={18} /></button>
          <button className="round" onClick={history.redo} disabled={!history.canRedo} aria-label="Redo" title="Redo (⇧⌘Z)"><Icon name="redo" size={18} /></button>
          <Link className="button secondary small" to={`/app/books/${id}/preview`}><Icon name="eye" size={18} />Preview</Link>
          <Menu label="Book" items={[
            { label: 'Delete book', icon: 'trash', destructive: true, onClick: async () => {
              if (!window.confirm(`Delete “${doc.title}”? This can't be undone.`)) return
              await api.deleteBook(id)
              savedDoc.current = history.current()
              setSave('saved')
              go('/app/books', { replace: true })
            } },
          ]} />
        </header>
        {view === 'pages' ? <PagesView bag={bag} />
          : view === 'cover' ? <CoverView bag={bag} />
          : view === 'order' ? <OrderView bag={bag} />
          : <Editor bag={bag} />}
        {view === 'preview' && <Preview doc={doc} start={spread} onClose={() => go(`/app/books/${id}`, { replace: true })} />}
        {save === 'conflict' && (
          <Sheet title="Changed somewhere else" onClose={() => {}}>
            <p className="sheet-text">This book was saved from another tab or device since you opened it. Keep your version here, or load the other one.</p>
            <div className="actions">
              <button className="secondary" onClick={load}>Load the other one</button>
              <button className="primary" onClick={async () => {
                const current = history.current()
                revision.current = await api.overwriteBook(id, { title: current.title.trim() || 'Untitled book', doc: current })
                savedDoc.current = current
                setSave('saved')
              }}>Keep mine</button>
            </div>
          </Sheet>
        )}
      </div>
    </BookContext.Provider>
  )
}

/** Reading the book as it'll print: the cover, then every spread. */
export function Preview({ doc, start = 0, onClose }) {
  const spreads = spreadsOf(doc.pages.map((_, i) => i))
  const [n, setN] = useState(start ? start + 1 : 0)
  const last = spreads.length
  useEffect(() => {
    const key = (e) => {
      if (e.key === 'Escape') onClose()
      if (e.key === 'ArrowRight' || e.key === ' ') { e.preventDefault(); setN((x) => Math.min(last, x + 1)) }
      if (e.key === 'ArrowLeft') setN((x) => Math.max(0, x - 1))
    }
    window.addEventListener('keydown', key)
    document.body.classList.add('locked')
    return () => { window.removeEventListener('keydown', key); document.body.classList.remove('locked') }
  }, [last, onClose])
  return (
    <div className="preview" role="dialog" aria-modal="true" aria-label="Preview">
      <div className="preview-top">
        <button className="round" onClick={onClose} aria-label="Close preview"><Icon name="close" /></button>
        <b>{doc.title}</b>
      </div>
      <div className="preview-stage" onClick={(e) => { if (e.target === e.currentTarget) setN((x) => Math.min(last, x + 1)) }}>
        {n === 0 ? <BookCover key="cover" doc={doc} /> : <BookSpread key={n} doc={doc} spread={n - 1} />}
        <button className="round prev" disabled={n === 0} onClick={() => setN(n - 1)} aria-label="Back"><Icon name="back" /></button>
        <button className="round next" disabled={n === last} onClick={() => setN(n + 1)} aria-label="Forward"><Icon name="forward" /></button>
      </div>
      <div className="preview-bottom">{n === 0 ? 'Cover' : n === 1 ? 'Page 1' : (() => { const [l, r] = spreads[n - 1]; return r === null ? `Page ${l + 1}` : `Pages ${l + 1}–${r + 1}` })()} · {doc.pages.length} pages</div>
    </div>
  )
}

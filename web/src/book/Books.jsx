// Your books, and starting a new one from batches: yours, and friends' that are shared with you.
import { useEffect, useMemo, useState } from 'react'
import * as api from '../api.js'
import { fontFamily } from '../look.js'
import { Icon, Link, Pile, Sheet, Spinner, counted, go, relative, shortDate } from '../ui.jsx'
import { createDoc, personName } from './doc.js'
import { defaultFormat, formats, money, priceCents } from './format.js'
import { BookContext, BookCover } from './render.jsx'

export function BooksPage({ ctx }) {
  const [state, setState] = useState({ books: undefined, photos: {}, error: null })
  useEffect(() => {
    let live = true
    api.books().then(async (books) => {
      const ids = books.map((b) => b.doc?.cover?.photo).filter(Boolean)
      const rows = await api.photosByIDs(ids).catch(() => [])
      if (live) setState({ books, photos: Object.fromEntries(rows.map((p) => [p.id, p])), error: null })
    }).catch((error) => live && setState({ books: null, photos: {}, error }))
    return () => { live = false }
  }, [])
  const context = useMemo(() => ({ photos: state.photos, batches: {}, me: ctx.me.id }), [state.photos, ctx.me.id])
  return (
    <main>
      <header className="pagehead">
        <h1 className="title big">Books</h1>
        <p className="meta">Printed photo books from your batches and your friends'.</p>
      </header>
      {state.error && <p className="problem">{state.error.message}</p>}
      {state.books === undefined && <Spinner />}
      {state.books && (
        <BookContext.Provider value={context}>
          <div className="bookgrid">
            <Link className="bookcard new" to="/app/books/new"><Icon name="plus" size={28} /><span>New book</span></Link>
            {state.books.map((b) => (
              <Link key={b.id} className="bookcard" to={`/app/books/${b.id}`}>
                <BookCover doc={{ ...b.doc, cover: { cloth: 'oat', ...b.doc?.cover } }} />
                <h3 className="card-title">{b.title}</h3>
                <p className="meta">{counted(b.doc?.pages?.length ?? 0, 'page')} · {b.status === 'ordered' ? 'Ordered' : `Edited ${relative(b.updated_at)}`}</p>
              </Link>
            ))}
          </div>
        </BookContext.Provider>
      )}
    </main>
  )
}

/** A batch you can tick for a book. */
export function PickableBatch({ batch, on, onToggle, showOwner }) {
  return (
    <button type="button" className={`pickable batch-card ${on ? 'on' : ''}`} aria-pressed={on} onClick={onToggle}>
      <span className="check" aria-hidden="true">✓</span>
      <Pile batch={batch} />
      <h3 className="card-title" style={{ fontFamily: fontFamily(batch.font) }}>{batch.title}</h3>
      <p className="meta">
        {showOwner ? `${personName(batch.owner)} · ` : ''}{counted(batch.photos.length, 'frame')}{batch.shot_on ? ` · ${shortDate(batch.shot_on)}` : ''}
      </p>
    </button>
  )
}

export function NewBookPage({ picked: initial, ctx }) {
  const { me } = ctx
  const [mine, setMine] = useState(undefined)
  const [friends, setFriends] = useState([])
  const [picked, setPicked] = useState(initial)
  const [sheet, setSheet] = useState(initial.length > 0)
  const [error, setError] = useState(null)
  useEffect(() => {
    api.batchesOf(me.id).then((b) => setMine(b.filter((x) => x.photos.length))).catch(setError)
    api.feed(me.id).then((b) => setFriends(b.filter((x) => x.photos.length && !ctx.blocked.has(x.owner_id)))).catch(() => {})
  }, [me.id]) // eslint-disable-line react-hooks/exhaustive-deps
  const all = useMemo(() => new Map([...(mine ?? []), ...friends].map((b) => [b.id, b])), [mine, friends])
  const chosen = picked.map((id) => all.get(id)).filter(Boolean)
  const toggle = (id) => setPicked((p) => (p.includes(id) ? p.filter((x) => x !== id) : [...p, id]))

  return (
    <main>
      <header className="pagehead">
        <h1 className="title big">New book</h1>
        <p className="meta">Pick the batches to put in it. Each becomes a chapter, in the order you pick them.</p>
      </header>
      {error && <p className="problem">{error.message}</p>}
      {mine === undefined && <Spinner />}
      {mine && (
        <>
          <h2 className="section-title">Your batches</h2>
          {!mine.length && <p className="meta">No batches with photos yet.</p>}
          <div className="grid">{mine.map((b) => <PickableBatch key={b.id} batch={b} on={picked.includes(b.id)} onToggle={() => toggle(b.id)} />)}</div>
          {friends.length > 0 && (
            <>
              <h2 className="section-title">Shared with you</h2>
              <p className="meta" style={{ marginTop: -6, marginBottom: 12 }}>Friends' photos are credited to them in the book.</p>
              <div className="grid">{friends.map((b) => <PickableBatch key={b.id} batch={b} showOwner on={picked.includes(b.id)} onToggle={() => toggle(b.id)} />)}</div>
            </>
          )}
          <div className="pickbar">
            <span className="meta">{chosen.length ? `${counted(chosen.length, 'batch', 'batches')} · ${counted(chosen.reduce((n, b) => n + b.photos.length, 0), 'photo')}` : 'Pick one or more batches'}</span>
            <Link className="button secondary" to="/app/books">Cancel</Link>
            <button className="primary" disabled={!chosen.length} onClick={() => setSheet(true)}>Continue</button>
          </div>
        </>
      )}
      {sheet && chosen.length > 0 && <NewBookSheet batches={chosen} me={me} onReorder={setPicked} onClose={() => setSheet(false)} />}
    </main>
  )
}

function NewBookSheet({ batches, me, onReorder, onClose }) {
  const [title, setTitle] = useState(batches.length === 1 ? batches[0].title : '')
  const [byline, setByline] = useState(me.display_name ?? '')
  const [mode, setMode] = useState('chapters')
  const [keepLook, setKeepLook] = useState(true)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')
  const format = formats[defaultFormat]
  const draft = useMemo(() => createDoc({ batches, title: title.trim() || 'Untitled book', byline: byline.trim(), mode, keepLook, me: me.id }),
    [batches, title, byline, mode, keepLook, me.id])
  const move = (i, d) => {
    const ids = batches.map((b) => b.id)
    ids.splice(i + d, 0, ids.splice(i, 1)[0])
    onReorder(ids)
  }
  const create = async () => {
    setBusy(true); setProblem('')
    try {
      const id = await api.createBook({ title: draft.title, format: draft.format, doc: draft, batchIDs: batches.map((b) => b.id) })
      go(`/app/books/${id}`, { replace: true })
    } catch (e) { setProblem(e.message); setBusy(false) }
  }
  return (
    <Sheet title="New book" onClose={onClose}>
      <label className="label" htmlFor="book-title">Title</label>
      <input id="book-title" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Summer 2026" maxLength={120} autoFocus />
      <label className="label" htmlFor="book-byline">Under the title</label>
      <input id="book-byline" value={byline} onChange={(e) => setByline(e.target.value)} placeholder="Your name, or who's in it" maxLength={120} />
      {batches.length > 1 && (
        <>
          <span className="label">Chapters</span>
          <div className="chips">
            {batches.map((b, i) => (
              <div className="chip" key={b.id}>
                <b style={{ fontFamily: fontFamily(b.font) }}>{b.title}</b>
                {b.owner_id !== me.id && <span className="meta">{personName(b.owner)}</span>}
                <button className="round" disabled={i === 0} onClick={() => move(i, -1)} aria-label={`Move ${b.title} earlier`}><Icon name="up" size={16} /></button>
                <button className="round" disabled={i === batches.length - 1} onClick={() => move(i, 1)} aria-label={`Move ${b.title} later`}><Icon name="down" size={16} /></button>
              </div>
            ))}
          </div>
          <span className="label">Arrange</span>
          <div className="segmented" role="radiogroup">
            <button role="radio" aria-checked={mode === 'chapters'} className={mode === 'chapters' ? 'on' : ''} onClick={() => setMode('chapters')}>A chapter per batch</button>
            <button role="radio" aria-checked={mode === 'date'} className={mode === 'date' ? 'on' : ''} onClick={() => setMode('date')}>All by date</button>
          </div>
        </>
      )}
      <label className="checkline"><input type="checkbox" checked={keepLook} onChange={(e) => setKeepLook(e.target.checked)} /> Keep each batch's frames, colours and font</label>
      <div className="estimate">
        <span><b>{format.title}</b> · {format.detail}<br /><span className="meta">{counted(draft.pages.length, 'page')}, laid out for you. Change anything after.</span></span>
        <b>{money(priceCents(format, draft.pages.length))}</b>
      </div>
      {problem && <p className="problem">{problem}</p>}
      <div className="actions">
        <button className="secondary" onClick={onClose}>Back</button>
        <button className="primary" disabled={busy} onClick={create}>{busy ? 'Making…' : 'Make the book'}</button>
      </div>
    </Sheet>
  )
}

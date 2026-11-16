// The book editor on made-up batches, without signing in: /app/book-dev.html in `npm run dev`.
// Photos have no shared copies, so they draw as grey boxes. Not part of the build.
import { useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../styles.css'
import { createDoc } from './doc.js'
import { formatOf } from './format.js'
import { useHistory } from './history.js'
import { BookContext } from './render.jsx'
import { Editor } from './Editor.jsx'
import { CoverView, PagesView } from './Pages.jsx'
import { OrderView } from './Order.jsx'
import { Preview } from './Book.jsx'

let n = 0
const photo = (w, h, extra = {}) => ({ id: `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`, pixel_width: w, pixel_height: h, share_path: null, captured_at: `2026-06-${String(n).padStart(2, '0')}`, ...extra })
const shapes = [[4032, 3024], [3024, 4032], [4032, 3024], [4032, 3024], [3024, 4032], [3024, 4032], [8000, 2400], [4032, 3024], [3000, 3000], [4032, 3024]]
const me = 'me'
const batches = [
  { id: 'b1', owner_id: me, title: 'Lisbon in June', shot_on: '2026-06-02', place: 'Lisbon', font: 'didot', frame: { kind: 'polaroid' }, background: 'kraft',
    photos: shapes.map(([w, h], i) => photo(w, h, i === 0 ? { caption: 'Alfama, morning' } : {})) },
  { id: 'b2', owner_id: 'maya', owner: { id: 'maya', display_name: 'Maya' }, title: 'The lake house', shot_on: '2026-08-14', place: 'Muskoka', font: 'classic', frame: { kind: 'whiteBorder' }, background: 'light',
    photos: shapes.slice(0, 7).map(([w, h]) => photo(w, h)) },
  { id: 'b3', owner_id: me, title: 'Night roll', shot_on: '2026-09-20', font: 'typewriter', frame: { kind: 'filmStrip' }, background: 'dark',
    photos: shapes.slice(3, 9).map(([w, h], i) => photo(w, h, i === 1 ? { added_by: 'theo', adder: { id: 'theo', handle: 'theo' } } : {})) },
]

function Dev() {
  const history = useHistory(createDoc({ batches, title: 'Summer 2026', byline: 'Kevin, Maya & Theo', me }))
  const [view, setView] = useState('edit')
  const [spread, setSpread] = useState(0)
  const [focus, setFocus] = useState(null)
  const revision = useRef(1)
  const photos = useMemo(() => Object.fromEntries(batches.flatMap((b) => b.photos.map((p) => [p.id, p]))), [])
  const byID = useMemo(() => Object.fromEntries(batches.map((b) => [b.id, b])), [])
  const doc = history.doc
  const bag = {
    id: 'dev', doc, apply: history.apply, undo: history.undo, redo: history.redo, photos, batches: byID, addBatch: () => {}, me,
    ctx: { me: { id: me }, blocked: new Set() }, format: formatOf(doc), spread, setSpread, focus, setFocus, revision, saveNow: () => {}, save: 'saved',
  }
  window.__book = { doc, photos, batches: byID, me }
  return (
    <BookContext.Provider value={{ photos, batches: byID, me }}>
      <div className="bookapp">
        <header className="bookbar">
          <b>{doc.title}</b>
          <nav className="booktabs">
            {['edit', 'pages', 'cover', 'order', 'preview'].map((v) => <a key={v} href="#" className={view === v ? 'on' : ''} onClick={(e) => { e.preventDefault(); setView(v) }}>{v}</a>)}
          </nav>
          <button className="round" onClick={history.undo} disabled={!history.canUndo}>↶</button>
          <button className="round" onClick={history.redo} disabled={!history.canRedo}>↷</button>
        </header>
        {view === 'pages' ? <PagesView bag={bag} /> : view === 'cover' ? <CoverView bag={bag} /> : view === 'order' ? <OrderView bag={bag} /> : <Editor bag={bag} />}
        {view === 'preview' && <Preview doc={doc} onClose={() => setView('edit')} />}
      </div>
    </BookContext.Provider>
  )
}

createRoot(document.getElementById('root')).render(<Dev />)

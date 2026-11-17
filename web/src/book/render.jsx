// Book pages on screen. Sizes are in cqw, a hundredth of the page's width, so one page draws the
// same as a thumbnail, in a spread and in the page editor. print.js draws the same geometry onto
// a canvas for the printer.
import { createContext, useContext } from 'react'
import { Photo } from '../ui.jsx'
import { captionFamily, fontFamily } from '../look.js'
import { aspectOf, coverLayout, coverPhotoBox, formatOf, framePadding, lineHeight, printBox, safeMargin, spreadsOf } from './format.js'
import { backgroundColor, chapterOf, cloths, photoCredit, spillInto, textColor } from './doc.js'
import './book.css'

/** What pages need beyond the document: photos by id, batches by id and who's looking. */
export const BookContext = createContext({ photos: {}, batches: {}, me: null })

export const textFamily = (font) => (font === 'mono' ? 'var(--mono)' : fontFamily(font))
export const pct = (v) => `${v * 100}cqw`

/**
 * One page. `selected` and the pointer handlers make it editable; `handles` adds resize and turn
 * handles to the selected item. `guides` draws the lines a dragged item snapped to, and
 * `showSafe` the area that stays clear of the trim, both for the editor only.
 */
export function BookPage({ doc, index, className = '', selected = [], onItemDown, onPageDown, handles = false, onHandleDown, onDrop, onDragOver, style, guides, showSafe }) {
  const page = doc.pages[index]
  if (!page) return <div className={`bpage endpaper ${className}`} style={{ background: cloths[doc.cover.cloth]?.color, ...style }} />
  const spill = spillInto(doc, index)
  const items = [...spill.map((i) => ({ ...i, x: i.x - 1, spill: true })), ...page.items].sort((a, b) => a.z - b.z)
  return (
    <div className={`bpage bg-${page.background} ${className}`} style={{ background: backgroundColor(page.background), ...style }}
         onPointerDown={onPageDown} onDrop={onDrop} onDragOver={onDragOver} data-page={page.id}>
      {items.map((item) => (
        <Item key={(item.spill ? 's' : '') + item.id} doc={doc} page={page} item={item} selected={!item.spill && selected.includes(item.id)}
              onDown={!item.spill && onItemDown ? (e) => onItemDown(e, item) : undefined}
              handles={handles && !item.spill && selected.length === 1 && selected[0] === item.id} onHandleDown={onHandleDown} />
      ))}
      {!page.items.length && !spill.length && onPageDown && <span className="bpage-empty">Drop photos here</span>}
      {showSafe && (
        <div className="bsafe" aria-hidden="true" style={{ inset: pct(safeMargin(formatOf(doc))) }}>
          <span className="bcenter v" /><span className="bcenter h" />
        </div>
      )}
      {guides?.xs.map((x) => <span key={`x${x}`} className="bguide v" style={{ left: pct(x) }} aria-hidden="true" />)}
      {guides?.ys.map((y) => <span key={`y${y}`} className="bguide h" style={{ top: pct(y) }} aria-hidden="true" />)}
    </div>
  )
}

function Item({ doc, page, item, selected, onDown, handles, onHandleDown }) {
  if (item.kind === 'text') {
    return (
      <div className={`bitem btext ${selected ? 'selected' : ''} ${onDown ? 'live' : ''}`} data-id={item.id} onPointerDown={onDown} style={{
        left: pct(item.x), top: pct(item.y), zIndex: item.z,
        transform: `translate(-50%, -50%) rotate(${item.rotation}deg)`,
        fontFamily: textFamily(item.font), fontSize: pct(item.size), lineHeight,
        fontStyle: item.italic ? 'italic' : undefined, color: textColor(item.color, page.background),
        letterSpacing: item.font === 'mono' ? '.12em' : undefined,
      }}>
        {item.text || ' '}
        {handles && <Handles item={item} onHandleDown={onHandleDown} />}
      </div>
    )
  }
  return <PhotoItem doc={doc} page={page} item={item} selected={selected} onDown={onDown} handles={handles} onHandleDown={onHandleDown} />
}

function PhotoItem({ doc, page, item, selected, onDown, handles, onHandleDown }) {
  const { photos, batches, me } = useContext(BookContext)
  const photo = photos[item.photo]
  const box = printBox(item, item.aspect, item.frame)
  const [t, r, b, l] = framePadding(item.frame).map((f) => f * item.w)
  const chapter = chapterOf(doc, page.chapter)
  const credit = doc.credits && !item.spill ? photoCredit(photo, batches[chapter?.batch], me) : ''
  return (
    <div className={`bitem bprint bf-${item.frame} ${selected ? 'selected' : ''} ${onDown ? 'live' : ''}`} data-id={item.id} onPointerDown={onDown} style={{
      left: pct(item.x - box.w / 2), top: pct(item.y - box.h / 2), width: pct(box.w), height: pct(box.h), zIndex: item.z,
      padding: `${pct(t)} ${pct(r)} ${pct(b)} ${pct(l)}`, transform: item.rotation ? `rotate(${item.rotation}deg)` : undefined,
    }}>
      {photo ? <Photo photo={photo} className="bphoto" /> : <div className="bphoto gone" title="No longer shared with you" />}
      {item.frame === 'polaroid' && photo?.caption && (
        <span className="bcaption" style={{ height: pct(b), left: pct(l), right: pct(r), fontFamily: captionFamily(chapter?.font), fontSize: pct(Math.min(b * 0.36, 0.03)) }}>{photo.caption}</span>
      )}
      {credit && <span className="bcredit">{credit}</span>}
      {handles && <Handles item={item} onHandleDown={onHandleDown} />}
    </div>
  )
}

function Handles({ item, onHandleDown }) {
  return (
    <>
      {['nw', 'ne', 'sw', 'se'].map((c) => <span key={c} className={`bhandle ${c}`} onPointerDown={(e) => onHandleDown?.(e, item, c)} />)}
      <span className="bhandle turn" onPointerDown={(e) => onHandleDown?.(e, item, 'turn')} title="Turn" />
    </>
  )
}

/** Two facing pages. The first and last spreads face the inside of the cover. */
export function BookSpread({ doc, spread, className = '', pageProps = () => ({}) }) {
  const pairs = spreadsOf(doc.pages.map((_, i) => i))
  const [left, right] = pairs[spread] ?? [null, null]
  return (
    <div className={`bspread ${className}`}>
      <BookPage doc={doc} index={left ?? -1} className="left" {...(left !== null ? pageProps(left) : {})} />
      <BookPage doc={doc} index={right ?? -1} className="right" {...(right !== null ? pageProps(right) : {})} />
      <span className="bfold" aria-hidden="true" />
    </div>
  )
}

/** The front of the book: cloth, the cover photo tipped in, the title. */
export function BookCover({ doc, className = '' }) {
  const { photos } = useContext(BookContext)
  const cloth = cloths[doc.cover.cloth] ?? cloths.oat
  const photo = photos[doc.cover.photo]
  const box = coverPhotoBox(photo ? aspectOf(photo) : 1)
  return (
    <div className={`bcover ${className}`} style={{ background: cloth.color, color: cloth.ink }}>
      <div className={`bcover-photo ${photo ? '' : 'empty'}`} style={{ left: pct(box.x - box.w / 2), top: pct(box.y - box.h / 2), width: pct(box.w), height: pct(box.h) }}>
        {photo ? <Photo photo={photo} /> : 'Choose a cover photo'}
      </div>
      <div className="bcover-text" style={{ top: pct(coverLayout.titleY), fontFamily: textFamily(doc.cover.font), fontSize: pct(coverLayout.titleSize) }}>{doc.cover.title || doc.title}</div>
      {doc.byline && <div className="bcover-text mono" style={{ top: pct(coverLayout.bylineY), fontSize: pct(coverLayout.bylineSize) }}>{doc.byline}</div>}
    </div>
  )
}

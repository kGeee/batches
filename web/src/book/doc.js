// A book's document: what's on every page, as saved in books.doc. Everything here is a pure
// function from one document to the next, which is what undo, autosave and the tests rely on.
//
// {
//   v: 1, format, title, byline, credits,
//   cover: { photo, cloth, font, title },
//   chapters: [{ id, batch, title, subtitle, credit, font, background, frame }],
//   pages: [{ id, chapter, background, layout, items: [photo or text item] }],
// }
// A photo item: { id, kind: 'photo', photo, aspect, frame, x, y, w, rotation, z }
// A text item:  { id, kind: 'text', text, x, y, size, font, rotation, color, italic }
// x and y are the item's centre in page units; a photo's height follows from its shape and frame.
import { aspectOf, bookFrame, defaultFormat, evenPages, formatOf, formats, frameKinds, isLeftPage, spreadIndexOf } from './format.js'
import { acrossSpread, groupPhotos, newID, openerItems, photoItems, photoPage, scatter, templatesFor, titleItems } from './layout.js'

export const docVersion = 1
export const maxItemsPerPage = 24
export const maxTextLength = 400

// Looks ----------------------------------------------------------------------------------------

/** Page colours. A batch's own hex colour is allowed too. */
export const backgrounds = {
  paper: { title: 'Paper', color: '#fbfaf6' },
  linen: { title: 'Linen', color: '#e6dfd2' },
  kraft: { title: 'Kraft', color: '#ccb087' },
  dark: { title: 'Dark', color: '#171614' },
}
export const backgroundColor = (bg) => backgrounds[bg]?.color ?? (/^#[0-9a-f]{6}$/i.test(bg ?? '') ? bg : backgrounds.paper.color)
export function isDark(bg) {
  const v = parseInt(backgroundColor(bg).slice(1), 16)
  const [r, g, b] = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((c) => c / 255)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.45
}
/** A text item's colour on a background: 'ink', 'muted', 'accent' or a hex colour. */
export function textColor(color, bg) {
  const dark = isDark(bg)
  if (/^#[0-9a-f]{6}$/i.test(color ?? '')) return color
  if (color === 'accent') return dark ? '#f0b44c' : '#9a5d12'
  if (color === 'muted') return dark ? '#9a958a' : '#6f6a60'
  return dark ? '#f3f1ec' : '#1d1b17'
}

export const cloths = {
  oat: { title: 'Oat linen', color: '#d9cfbd', ink: '#2a251d' },
  slate: { title: 'Slate', color: '#4a5059', ink: '#f1eee7' },
  rust: { title: 'Rust', color: '#9b4a2c', ink: '#f6ecdf' },
  forest: { title: 'Forest', color: '#34473a', ink: '#efeadd' },
  black: { title: 'Black', color: '#1c1b1a', ink: '#e9e4d8' },
}
export const bookFonts = ['classic', 'didot', 'modern', 'futura', 'typewriter', 'rounded', 'handwritten']

/** A batch's page colour, from its background in the app. */
export function pageBackgroundOf(batch) {
  if (batch.frame?.kind === 'filmStrip') return 'dark'
  const raw = batch.background ?? batch.frame?.wall ?? 'light'
  if (raw === 'dark' || raw === 'kraft') return raw
  if (raw === 'desk') return 'linen'
  if (/^#[0-9a-f]{6}$/i.test(raw)) return raw.toLowerCase()
  return 'paper'
}

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
function monthYear(date) {
  const d = new Date(`${String(date).slice(0, 10)}T12:00:00`)
  return Number.isNaN(d.getTime()) ? '' : `${months[d.getMonth()]} ${d.getFullYear()}`
}
export const personName = (p) => p?.display_name || (p?.handle ? `@${p.handle}` : 'a friend')

/** Who a batch's photos are by, when that isn't only you. */
export function creditLine(batch, me) {
  const others = [...new Map(batch.photos.filter((p) => p.adder && p.added_by !== batch.owner_id).map((p) => [p.added_by, p.adder])).values()]
  const owner = batch.owner_id !== me ? `Photos by ${personName(batch.owner)}` : ''
  const withOthers = others.filter((p) => p.id !== me).map(personName)
  if (owner && withOthers.length) return `${owner} with ${withOthers.join(', ')}`
  if (owner) return owner
  return withOthers.length ? `With ${withOthers.join(', ')}` : ''
}

/** The small line under a photo someone else added, when credits are on. */
export function photoCredit(photo, chapterBatch, me) {
  if (!photo) return ''
  const by = photo.added_by && photo.added_by !== chapterBatch?.owner_id ? photo.adder : null
  if (by && by.id !== me) return personName(by)
  return ''
}

// Making a book --------------------------------------------------------------------------------

export function chapterFor(batch, keepLook, me) {
  return {
    id: newID('c'),
    batch: batch.id,
    title: batch.title || 'Untitled',
    subtitle: [batch.shot_on && monthYear(batch.shot_on), batch.place].filter(Boolean).join(' · '),
    credit: creditLine(batch, me),
    font: keepLook ? batch.font ?? 'classic' : 'classic',
    background: keepLook ? pageBackgroundOf(batch) : 'paper',
    frame: keepLook ? bookFrame(batch.frame?.kind) : 'whiteBorder',
  }
}

/** A chapter's pages: its opener, then its photos in rhythm. */
export function chapterPages(chapter, index, photos, format, opener = true) {
  const pages = []
  if (opener) pages.push({ id: newID('p'), chapter: chapter.id, background: chapter.background, layout: 'text', items: openerItems(chapter, index) })
  for (const group of groupPhotos(photos)) pages.push(photoPage(group, group.map(() => chapter.frame), chapter, format))
  return pages
}

const blankPage = (chapter, background = 'paper') => ({ id: newID('p'), chapter: chapter ?? null, background, layout: 'blank', items: [] })

/** Blank pages at the end so the book has an even count and at least the format's minimum. */
export function padPages(pages, format) {
  const target = evenPages(pages.length, format)
  const out = [...pages]
  while (out.length < target) out.push(blankPage(null))
  return out
}

/**
 * A first draft from batches, laid out automatically.
 * mode 'chapters': each batch is a chapter with an opener. mode 'date': every photo in time order.
 */
export function createDoc({ batches, title, byline = '', mode = 'chapters', keepLook = true, me, format = defaultFormat }) {
  const f = formats[format] ?? formats[defaultFormat]
  const chapters = batches.map((b) => chapterFor(b, keepLook, me))
  const coverFont = keepLook && batches[0]?.font ? batches[0].font : 'didot'
  const pages = [{ id: newID('p'), chapter: null, background: 'paper', layout: 'text', items: titleItems(title, byline, coverFont) }]
  if (mode === 'date') {
    const frameOf = new Map()
    batches.forEach((b, i) => b.photos.forEach((p) => frameOf.set(p.id, chapters[i])))
    const all = batches.flatMap((b) => b.photos).sort((a, b) => String(a.captured_at ?? a.created_at ?? '').localeCompare(String(b.captured_at ?? b.created_at ?? '')))
    for (const group of groupPhotos(all)) {
      const page = photoPage(group, group.map((p) => frameOf.get(p.id).frame), null, f)
      page.background = keepLook ? frameOf.get(group[0].id).background : 'paper'
      pages.push(page)
    }
  } else {
    batches.forEach((b, i) => pages.push(...chapterPages(chapters[i], i, b.photos, f)))
  }
  const cover = batches.map((b) => b.photos.find((p) => p.id === b.cover_photo_id) ?? b.photos[0]).find(Boolean)
  return {
    v: docVersion, format: f.id, title, byline, credits: true, mode,
    cover: { photo: cover?.id ?? null, cloth: 'oat', font: coverFont, title },
    chapters,
    pages: padPages(pages, f),
  }
}

// Reading a saved book -------------------------------------------------------------------------

const num = (v, lo, hi, d) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d)
const str = (v, max, d = '') => (typeof v === 'string' ? v.slice(0, max) : d)

function cleanItem(item) {
  if (!item || typeof item !== 'object') return null
  const base = { id: str(item.id, 40) || newID('i'), x: num(item.x, -1, 3, 0.5), y: num(item.y, -1, 2, 0.5), rotation: num(item.rotation, -45, 45, 0), z: Math.round(num(item.z, -999, 999, 0)) }
  if (item.kind === 'photo' && typeof item.photo === 'string') {
    return { ...base, kind: 'photo', photo: item.photo, aspect: num(item.aspect, 0.1, 10, 1), frame: frameKinds.includes(item.frame) ? item.frame : 'whiteBorder', w: num(item.w, 0.04, 2, 0.4) }
  }
  if (item.kind === 'text') {
    return { ...base, kind: 'text', text: str(item.text, maxTextLength), size: num(item.size, 0.01, 0.25, 0.04), font: str(item.font, 20, 'classic'), color: str(item.color, 10, 'ink'), italic: item.italic === true }
  }
  return null
}

/** A document as saved, held to what the editor can make. Anything unreadable is dropped. */
export function cleanDoc(raw) {
  const d = raw && typeof raw === 'object' ? raw : {}
  const f = formatOf(d)
  const chapters = (Array.isArray(d.chapters) ? d.chapters : []).filter((c) => c && typeof c === 'object').slice(0, 40).map((c) => ({
    id: str(c.id, 40) || newID('c'), batch: str(c.batch, 40) || null, title: str(c.title, 120), subtitle: str(c.subtitle, 120), credit: str(c.credit, 160),
    font: str(c.font, 20, 'classic'), background: str(c.background, 10, 'paper'), frame: frameKinds.includes(c.frame) ? c.frame : 'whiteBorder',
  }))
  const pages = (Array.isArray(d.pages) ? d.pages : []).filter((p) => p && typeof p === 'object').slice(0, f.maxPages).map((p) => ({
    id: str(p.id, 40) || newID('p'), chapter: str(p.chapter, 40) || null, background: str(p.background, 10, 'paper'), layout: str(p.layout, 30, 'free'),
    items: (Array.isArray(p.items) ? p.items : []).map(cleanItem).filter(Boolean).slice(0, maxItemsPerPage),
  }))
  const cover = d.cover && typeof d.cover === 'object' ? d.cover : {}
  return {
    v: docVersion, format: f.id, title: str(d.title, 120, 'Untitled book'), byline: str(d.byline, 120), credits: d.credits !== false, mode: d.mode === 'date' ? 'date' : 'chapters',
    cover: { photo: str(cover.photo, 40) || null, cloth: cloths[cover.cloth] ? cover.cloth : 'oat', font: str(cover.font, 20, 'didot'), title: str(cover.title, 120, str(d.title, 120)) },
    chapters,
    pages: padPages(pages, f),
  }
}

// Finding things -------------------------------------------------------------------------------

export const pageIndex = (doc, pageID) => doc.pages.findIndex((p) => p.id === pageID)
export const pageOf = (doc, pageID) => doc.pages.find((p) => p.id === pageID) ?? null
export const chapterOf = (doc, id) => doc.chapters.find((c) => c.id === id) ?? null

export function usedPhotoIDs(doc) {
  const used = new Set()
  for (const p of doc.pages) for (const i of p.items) if (i.kind === 'photo') used.add(i.photo)
  return used
}

/** Items from the page before that reach onto this one (a photo across a spread). */
export function spillInto(doc, index) {
  if (isLeftPage(index) || index === 0) return []
  const left = doc.pages[index - 1]
  if (!left) return []
  return left.items.filter((i) => i.kind === 'photo' && i.x + i.w / 2 > 1)
}

// Edits ----------------------------------------------------------------------------------------

const mapPage = (doc, pageID, fn) => ({ ...doc, pages: doc.pages.map((p) => (p.id === pageID ? fn(p) : p)) })
const photosOn = (page, photosByID) => page.items.filter((i) => i.kind === 'photo').sort((a, b) => a.z - b.z)
  .map((i) => ({ item: i, photo: photosByID[i.photo] ?? { id: i.photo, pixel_width: i.aspect * 1000, pixel_height: 1000 } }))

export const setTitle = (doc, title) => ({ ...doc, title, cover: { ...doc.cover, title: doc.cover.title === doc.title ? title : doc.cover.title } })
export const setCover = (doc, patch) => ({ ...doc, cover: { ...doc.cover, ...patch } })
export const setCredits = (doc, on) => ({ ...doc, credits: on })

export function updateItem(doc, pageID, itemID, patch, { free = false } = {}) {
  return mapPage(doc, pageID, (p) => ({ ...p, layout: free ? 'free' : p.layout, items: p.items.map((i) => (i.id === itemID ? { ...i, ...patch } : i)) }))
}

export function removeItem(doc, pageID, itemID, photosByID, format) {
  const page = pageOf(doc, pageID)
  const next = { ...page, items: page.items.filter((i) => i.id !== itemID) }
  return mapPage(doc, pageID, () => reflow(next, photosByID, format))
}

export function bringToFront(doc, pageID, itemID) {
  const page = pageOf(doc, pageID)
  const top = Math.max(0, ...page.items.map((i) => i.z)) + 1
  return updateItem(doc, pageID, itemID, { z: top })
}

/** Re-lays a page's photos with its template, when it has one. Freehand pages stay as they are. */
function reflow(page, photosByID, format) {
  if (!page.layout.startsWith('rows:') && page.layout !== 'blank') return page
  const entries = photosOn(page, photosByID)
  const texts = page.items.filter((i) => i.kind !== 'photo')
  if (!entries.length) return { ...page, layout: texts.length ? 'free' : 'blank', items: texts }
  const best = templatesFor(entries.map((e) => e.photo), entries.map((e) => e.item.frame), format)[0]
  return { ...page, layout: best.id, items: [...entries.map((e, n) => ({ ...e.item, x: best.placed[n].x, y: best.placed[n].y, w: best.placed[n].w, rotation: 0, z: n })), ...texts] }
}

/** Puts a photo on a page: where it was dropped on a freehand page, or into the page's template. */
export function addPhoto(doc, pageID, photo, photosByID, format, at = null) {
  const page = pageOf(doc, pageID)
  if (page.items.length >= maxItemsPerPage) return doc
  const chapter = chapterOf(doc, page.chapter)
  const frame = chapter?.frame ?? 'whiteBorder'
  const z = Math.max(-1, ...page.items.map((i) => i.z)) + 1
  const item = photoItems([photo], [frame], [{ x: at?.x ?? 0.5, y: at?.y ?? 0.5, w: aspectOf(photo) >= 1 ? 0.5 : 0.36 }], { z })[0]
  const next = { ...page, items: [...page.items, item] }
  const free = page.layout === 'free' || page.layout === 'text'
  return mapPage(doc, pageID, () => (free ? { ...next, layout: 'free' } : reflow({ ...next, layout: 'rows:auto' }, { ...photosByID, [photo.id]: photo }, format)))
}

export function swapPhoto(doc, pageID, itemID, photo, photosByID, format) {
  const page = pageOf(doc, pageID)
  const next = { ...page, items: page.items.map((i) => (i.id === itemID ? { ...i, photo: photo.id, aspect: aspectOf(photo) } : i)) }
  return mapPage(doc, pageID, () => reflow(next, { ...photosByID, [photo.id]: photo }, format))
}

/** Templates offered for a page, for the layout picker. */
export function layoutChoices(doc, pageID, photosByID, format) {
  const index = pageIndex(doc, pageID)
  const entries = photosOn(pageOf(doc, pageID), photosByID)
  if (!entries.length) return []
  const photos = entries.map((e) => e.photo), frames = entries.map((e) => e.item.frame)
  const choices = templatesFor(photos, frames, format).map((t) => ({ id: t.id, title: t.title, placed: t.placed }))
  choices.push({ id: 'scatter', title: 'Scattered', placed: scatter(photos, frames, format) })
  if (entries.length === 1 && isLeftPage(index) && doc.pages[index + 1]) choices.push({ id: 'spread', title: 'Across the spread', placed: [acrossSpread(photos[0], frames[0], format)] })
  return choices
}

export function applyLayout(doc, pageID, choice, photosByID) {
  const page = pageOf(doc, pageID)
  const entries = photosOn(page, photosByID)
  const texts = page.items.filter((i) => i.kind !== 'photo')
  const layout = choice.id === 'scatter' || choice.id === 'spread' ? (choice.id === 'spread' ? 'spread' : 'free') : choice.id
  return mapPage(doc, pageID, (p) => ({
    ...p, layout,
    items: [...entries.map((e, n) => ({ ...e.item, x: choice.placed[n].x, y: choice.placed[n].y, w: choice.placed[n].w, rotation: choice.placed[n].rotation ?? 0, z: n })), ...texts],
  }))
}

export function setFrame(doc, pageID, itemID, frame, photosByID, format) {
  const page = pageOf(doc, pageID)
  const next = { ...page, items: page.items.map((i) => (i.kind === 'photo' && (itemID === null || i.id === itemID) ? { ...i, frame } : i)) }
  return mapPage(doc, pageID, () => reflow(next, photosByID, format))
}

/** A frame for every photo in a chapter, and for photos added to it later. */
export function setChapterFrame(doc, chapterID, frame, photosByID, format) {
  let next = { ...doc, chapters: doc.chapters.map((c) => (c.id === chapterID ? { ...c, frame } : c)) }
  for (const p of doc.pages) if (p.chapter === chapterID) next = setFrame(next, p.id, null, frame, photosByID, format)
  return next
}

export function setBackground(doc, pageID, background, wholeChapter = false) {
  const page = pageOf(doc, pageID)
  if (!wholeChapter || !page.chapter) return mapPage(doc, pageID, (p) => ({ ...p, background }))
  return {
    ...doc,
    chapters: doc.chapters.map((c) => (c.id === page.chapter ? { ...c, background } : c)),
    pages: doc.pages.map((p) => (p.chapter === page.chapter ? { ...p, background } : p)),
  }
}

export function addText(doc, pageID, text = 'Words', at = null) {
  const page = pageOf(doc, pageID)
  if (page.items.length >= maxItemsPerPage) return doc
  const chapter = chapterOf(doc, page.chapter)
  const z = Math.max(-1, ...page.items.map((i) => i.z)) + 1
  const item = { id: newID('t'), kind: 'text', text, x: at?.x ?? 0.5, y: at?.y ?? 0.5, size: 0.04, font: chapter?.font ?? doc.cover.font ?? 'classic', rotation: 0, z, color: 'ink', italic: false }
  return { doc: mapPage(doc, pageID, (p) => ({ ...p, layout: p.layout === 'blank' ? 'free' : p.layout, items: [...p.items, item] })), item }
}

// Pages ----------------------------------------------------------------------------------------

/** Moves the spread at `from` to sit at `to`. The first spread (page 1 alone) stays put. */
export function moveSpread(doc, from, to) {
  if (from === to || from < 1 || to < 1) return doc
  const pairs = []
  for (let i = 1; i < doc.pages.length; i += 2) pairs.push(doc.pages.slice(i, i + 2))
  const [moved] = pairs.splice(from - 1, 1)
  if (!moved) return doc
  pairs.splice(Math.min(to - 1, pairs.length), 0, moved)
  return { ...doc, pages: [doc.pages[0], ...pairs.flat()] }
}

/** Indices of a chapter's pages, in order. */
export const chapterPageIndices = (doc, chapterID) => doc.pages.map((p, i) => (p.chapter === chapterID ? i : -1)).filter((i) => i >= 0)

/** Moves a chapter's pages before or after its neighbour's. */
export function moveChapter(doc, chapterID, delta) {
  const order = doc.chapters.map((c) => c.id)
  const at = order.indexOf(chapterID), to = at + delta
  if (at < 0 || to < 0 || to >= order.length) return doc
  order.splice(to, 0, order.splice(at, 1)[0])
  return reorderChapters(doc, order)
}

/** Chapters in a new order: each chapter's pages move together; pages outside chapters stay first or last. */
export function reorderChapters(doc, order) {
  const first = [], last = []
  const byChapter = new Map(order.map((id) => [id, []]))
  let seen = false
  for (const p of doc.pages) {
    if (p.chapter && byChapter.has(p.chapter)) { byChapter.get(p.chapter).push(p); seen = true } else (seen ? last : first).push(p)
  }
  const chapters = order.map((id) => chapterOf(doc, id)).filter(Boolean)
  const renumbered = renumber({ ...doc, chapters }, [...first, ...order.flatMap((id) => byChapter.get(id)), ...last])
  return { ...doc, chapters, pages: renumbered }
}

/** Keeps opener numerals (I, II…) in chapter order. */
function renumber(doc, pages) {
  const romans = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII']
  return pages.map((p) => {
    if (p.layout !== 'text' || !p.chapter) return p
    const n = doc.chapters.findIndex((c) => c.id === p.chapter)
    return { ...p, items: p.items.map((i) => (i.kind === 'text' && i.color === 'accent' && romans.includes(i.text) ? { ...i, text: romans[n] ?? String(n + 1) } : i)) }
  })
}

/** Two blank pages after `index`, so the spreads after stay paired. */
export function addSpread(doc, index, format) {
  if (doc.pages.length + 2 > format.maxPages) return doc
  const at = Math.max(1, index + 1 + ((index + 1) % 2 === 0 ? 1 : 0))
  const chapter = doc.pages[index]?.chapter ?? null
  const bg = doc.pages[index]?.background ?? 'paper'
  const pages = [...doc.pages]
  pages.splice(at, 0, blankPage(chapter, bg), blankPage(chapter, bg))
  return { ...doc, pages }
}

export function removeSpread(doc, spread, format) {
  if (spread < 1 || doc.pages.length - 2 < format.minPages) return doc
  const start = 2 * spread - 1
  const pages = [...doc.pages]
  pages.splice(start, 2)
  return { ...doc, pages: padPages(pages, format) }
}

/** Lays a chapter out again from its batch, keeping its place in the book. */
export function relayoutChapter(doc, chapterID, batch, format) {
  const index = doc.chapters.findIndex((c) => c.id === chapterID)
  if (index < 0) return doc
  const chapter = doc.chapters[index]
  const at = chapterPageIndices(doc, chapterID)
  const fresh = chapterPages(chapter, index, batch.photos, format)
  const pages = doc.pages.filter((p) => p.chapter !== chapterID)
  pages.splice(at.length ? at[0] : pages.length, 0, ...fresh)
  return { ...doc, pages: padPages(trimTrailingBlanks(pages), format) }
}

export function addChapter(doc, batch, keepLook, me, format) {
  const chapter = chapterFor(batch, keepLook, me)
  const chapters = [...doc.chapters, chapter]
  const pages = [...trimTrailingBlanks(doc.pages), ...chapterPages(chapter, chapters.length - 1, batch.photos, format)]
  if (pages.length > format.maxPages) return doc
  return { ...doc, chapters, pages: padPages(pages, format) }
}

export function removeChapter(doc, chapterID, format) {
  const chapters = doc.chapters.filter((c) => c.id !== chapterID)
  return { ...doc, chapters, pages: padPages(renumber({ ...doc, chapters }, doc.pages.filter((p) => p.chapter !== chapterID)), format) }
}

export function renameChapter(doc, chapterID, title) {
  const old = chapterOf(doc, chapterID)?.title
  return {
    ...doc,
    chapters: doc.chapters.map((c) => (c.id === chapterID ? { ...c, title } : c)),
    pages: doc.pages.map((p) => (p.chapter === chapterID && p.layout === 'text'
      ? { ...p, items: p.items.map((i) => (i.kind === 'text' && i.text === old ? { ...i, text: title } : i)) } : p)),
  }
}

function trimTrailingBlanks(pages) {
  const out = [...pages]
  while (out.length > 1 && out[out.length - 1].items.length === 0) out.pop()
  return out
}

export { spreadIndexOf }

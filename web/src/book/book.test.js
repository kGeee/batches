import { describe, expect, it } from 'vitest'
import { aspectOf, effectiveDPI, evenPages, formats, printAspect, printBox, spreadsOf, spreadIndexOf, isLeftPage, priceCents, safeMargin } from './format.js'
import { compositions, groupPhotos, rows, snapAxis, templatesFor, contentBox, wrapTitle } from './layout.js'
import { addPhoto, addSpread, cleanDoc, createDoc, creditLine, layoutChoices, applyLayout, moveChapter, moveSpread, removeItem, removeSpread, renameChapter, swapPhoto, usedPhotoIDs, chapterPageIndices, setBackground, relayoutChapter } from './doc.js'
import { preflight } from './preflight.js'
import { push, redo, start, undo } from './history.js'

const f = formats.square8
let seq = 0
const photo = (w, h, extra = {}) => ({ id: `00000000-0000-4000-8000-${String(++seq).padStart(12, '0')}`, pixel_width: w, pixel_height: h, captured_at: `2026-0${(seq % 9) + 1}-01`, ...extra })
const batch = (n, extra = {}) => {
  const photos = Array.from({ length: n }, (_, i) => (i % 3 === 0 ? photo(3000, 4000) : photo(4000, 3000)))
  return { id: `b${++seq}`, owner_id: 'me', title: 'Lisbon in June', shot_on: '2026-06-02', place: 'Lisbon', font: 'didot', frame: { kind: 'polaroid' }, background: 'kraft', photos, ...extra }
}
const byID = (...bs) => Object.fromEntries(bs.flatMap((b) => b.photos).map((p) => [p.id, p]))

describe('format', () => {
  it('rounds pages to even and the minimum', () => {
    expect(evenPages(3, f)).toBe(20)
    expect(evenPages(31, f)).toBe(32)
    expect(evenPages(500, f)).toBe(120)
  })
  it('prices extra pages', () => {
    expect(priceCents(f, 20)).toBe(3900)
    expect(priceCents(f, 30)).toBe(4900)
  })
  it('pairs pages into spreads with page 1 on the right', () => {
    const pages = [1, 2, 3, 4, 5, 6]
    expect(spreadsOf(pages)).toEqual([[null, 1], [2, 3], [4, 5], [6, null]])
    expect(spreadIndexOf(0)).toBe(0)
    expect(spreadIndexOf(1)).toBe(1)
    expect(spreadIndexOf(2)).toBe(1)
    expect(spreadIndexOf(3)).toBe(2)
    expect(isLeftPage(1)).toBe(true)
    expect(isLeftPage(2)).toBe(false)
  })
  it('keeps the photo shape inside a frame', () => {
    const box = printBox({ w: 0.5 }, 1.5, 'polaroid')
    expect(box.imageW / box.imageH).toBeCloseTo(1.5)
    expect(box.w / box.h).toBeCloseTo(printAspect(1.5, 'polaroid'))
    expect(printAspect(1.5, 'none')).toBeCloseTo(1.5)
  })
  it('computes print resolution from the largest shared copy', () => {
    // A 4000 px wide photo is shared at 1800 px; across a whole 8 in page that's 225 dpi.
    expect(effectiveDPI(photo(4000, 3000), 1, f)).toBeCloseTo(225)
    expect(effectiveDPI(photo(1200, 900), 0.5, f)).toBeCloseTo(300)
  })
})

describe('layout', () => {
  it('lists every split of photos into rows', () => {
    expect(compositions(3)).toEqual([[1, 1, 1], [1, 2], [2, 1], [3]])
    expect(compositions(4)).toHaveLength(8)
  })
  it('places prints inside the box without changing their shape', () => {
    const box = contentBox(f)
    const aspects = [1.5, 0.75, 1]
    for (const split of compositions(3)) {
      const { placed } = rows(aspects, split, box)
      placed.forEach((p, i) => {
        expect(p.w / p.h).toBeCloseTo(aspects[i])
        expect(p.x - p.w / 2).toBeGreaterThanOrEqual(box.x - 1e-9)
        expect(p.x + p.w / 2).toBeLessThanOrEqual(box.x + box.w + 1e-9)
        expect(p.y - p.h / 2).toBeGreaterThanOrEqual(box.y - 1e-9)
        expect(p.y + p.h / 2).toBeLessThanOrEqual(box.y + box.h + 1e-9)
      })
    }
  })
  it('prefers side by side for two portraits', () => {
    const t = templatesFor([photo(3000, 4000), photo(3000, 4000)], ['none', 'none'], f)
    expect(t[0].id).toBe('rows:2')
  })
  it('prefers stacked for two wide landscapes', () => {
    const t = templatesFor([photo(4000, 2000), photo(4000, 2000)], ['none', 'none'], f)
    expect(t[0].id).toBe('rows:1,1')
  })
  it('opens with a single hero, pairs portraits, and gives panoramas a page', () => {
    const ps = [photo(4000, 3000), photo(3000, 4000), photo(3000, 4000), photo(8000, 2000), photo(4000, 3000)]
    const groups = groupPhotos(ps).map((g) => g.length)
    expect(groups[0]).toBe(1)
    expect(groups[1]).toBe(2)
    expect(groups[2]).toBe(1)
    expect(groups.reduce((s, n) => s + n, 0)).toBe(5)
  })
  it('snaps an edge or centre to the nearest target within tolerance', () => {
    const left = snapAxis(0.305, 0.1, [0.5, 0.2], 0.01)
    expect(left.delta).toBeCloseTo(-0.005)
    expect(left.lines).toEqual([0.2])
    const centre = snapAxis(0.497, 0.1, [0.5, 0.2], 0.01)
    expect(centre.delta).toBeCloseTo(0.003)
    expect(centre.lines).toEqual([0.5])
    expect(snapAxis(0.45, 0.1, [0.5, 0.2], 0.01)).toEqual({ delta: 0, lines: [] })
  })
  it('wraps titles at spaces', () => {
    expect(wrapTitle('Summer at the lake house with everyone')).toEqual(['Summer at the', 'lake house with', 'everyone'])
  })
})

describe('doc', () => {
  it('makes a book with every photo once, an even page count, and chapter openers', () => {
    const a = batch(9), b = batch(5)
    const doc = createDoc({ batches: [a, b], title: 'Summer', me: 'me' })
    const used = usedPhotoIDs(doc)
    expect(used.size).toBe(14)
    expect(doc.pages.length % 2).toBe(0)
    expect(doc.pages.length).toBeGreaterThanOrEqual(20)
    expect(doc.chapters).toHaveLength(2)
    expect(doc.chapters[0].background).toBe('kraft')
    expect(doc.chapters[0].frame).toBe('polaroid')
    expect(doc.pages[1].layout).toBe('text')
    expect(doc.pages[1].items.map((i) => i.text)).toContain('Lisbon in June')
  })
  it('can ignore the batch look', () => {
    const doc = createDoc({ batches: [batch(3)], title: 'Plain', me: 'me', keepLook: false })
    expect(doc.chapters[0].background).toBe('paper')
    expect(doc.chapters[0].frame).toBe('whiteBorder')
  })
  it('orders by date without openers', () => {
    const a = batch(3), b = batch(3)
    const doc = createDoc({ batches: [a, b], title: 'Year', me: 'me', mode: 'date' })
    const order = doc.pages.flatMap((p) => p.items.filter((i) => i.kind === 'photo').map((i) => i.photo))
    const dates = order.map((id) => byID(a, b)[id].captured_at)
    expect([...dates].sort()).toEqual(dates)
    expect(doc.pages.filter((p) => p.layout === 'text')).toHaveLength(1)
  })
  it('credits friends whose batches are in the book', () => {
    const theirs = batch(2, { owner_id: 'maya', owner: { display_name: 'Maya' } })
    expect(creditLine(theirs, 'me')).toBe('Photos by Maya')
    const group = batch(2)
    group.photos[0].added_by = 'theo'
    group.photos[0].adder = { id: 'theo', handle: 'theo' }
    expect(creditLine(group, 'me')).toBe('With @theo')
  })
  it('survives a round trip and junk', () => {
    const doc = createDoc({ batches: [batch(6)], title: 'Trip', me: 'me' })
    expect(cleanDoc(JSON.parse(JSON.stringify(doc)))).toEqual(doc)
    const junk = cleanDoc({ pages: [{ items: [{ kind: 'photo' }, { kind: 'text', text: 3 }, { kind: 'photo', photo: 'x', w: 99 }] }] })
    expect(junk.pages).toHaveLength(20)
    expect(junk.pages[0].items).toHaveLength(2)
    expect(junk.pages[0].items[1].w).toBe(2)
  })
  it('adds, swaps and removes photos, keeping template pages tidy', () => {
    const a = batch(4)
    const photos = byID(a)
    let doc = createDoc({ batches: [a], title: 'T', me: 'me' })
    const page = doc.pages.find((p) => p.layout.startsWith('rows:'))
    const extra = photo(4000, 3000)
    doc = addPhoto(doc, page.id, extra, photos, f)
    const after = doc.pages.find((p) => p.id === page.id)
    expect(after.items.filter((i) => i.kind === 'photo')).toHaveLength(page.items.length + 1)
    expect(after.layout.startsWith('rows:')).toBe(true)
    const swapIn = photo(3000, 4000)
    doc = swapPhoto(doc, page.id, after.items[0].id, swapIn, { ...photos, [extra.id]: extra }, f)
    expect(doc.pages.find((p) => p.id === page.id).items.some((i) => i.photo === swapIn.id)).toBe(true)
    const target = doc.pages.find((p) => p.id === page.id).items[0]
    doc = removeItem(doc, page.id, target.id, { ...photos, [extra.id]: extra, [swapIn.id]: swapIn }, f)
    expect(doc.pages.find((p) => p.id === page.id).items.some((i) => i.id === target.id)).toBe(false)
  })
  it('offers templates, a scatter, and a spread for a single photo on a left page', () => {
    const a = batch(1)
    let doc = createDoc({ batches: [a], title: 'T', me: 'me' })
    const index = doc.pages.findIndex((p) => p.items.some((i) => i.kind === 'photo'))
    doc = moveSpread(doc, 2, 2)
    const choices = layoutChoices(doc, doc.pages[index].id, byID(a), f)
    expect(choices.map((c) => c.id)).toContain('scatter')
    const left = index % 2 === 1
    expect(choices.some((c) => c.id === 'spread')).toBe(left)
    doc = applyLayout(doc, doc.pages[index].id, choices.find((c) => c.id === 'scatter'), byID(a))
    expect(doc.pages[index].layout).toBe('free')
  })
  it('moves spreads and chapters as blocks', () => {
    const a = batch(4, { title: 'A' }), b = batch(4, { title: 'B' })
    let doc = createDoc({ batches: [a, b], title: 'T', me: 'me' })
    const ids = doc.pages.map((p) => p.id)
    const moved = moveSpread(doc, 1, 3)
    expect(moved.pages[0].id).toBe(ids[0])
    expect(moved.pages.slice(5, 7).map((p) => p.id)).toEqual(ids.slice(1, 3))
    const [ca, cb] = doc.chapters
    doc = moveChapter(doc, cb.id, -1)
    expect(doc.chapters.map((c) => c.id)).toEqual([cb.id, ca.id])
    const bPages = chapterPageIndices(doc, cb.id), aPages = chapterPageIndices(doc, ca.id)
    expect(Math.max(...bPages)).toBeLessThan(Math.min(...aPages))
    expect(doc.pages[bPages[0]].items.find((i) => i.color === 'accent').text).toBe('I')
  })
  it('adds and removes spreads, never below the minimum', () => {
    let doc = createDoc({ batches: [batch(2)], title: 'T', me: 'me' })
    expect(removeSpread(doc, 3, f).pages).toHaveLength(20)
    doc = addSpread(doc, 2, f)
    expect(doc.pages).toHaveLength(22)
    expect(doc.pages[3].items).toHaveLength(0)
    expect(removeSpread(doc, 2, f).pages).toHaveLength(20)
  })
  it('renames a chapter on its opener and relays it out', () => {
    const a = batch(5)
    let doc = createDoc({ batches: [a], title: 'T', me: 'me' })
    const c = doc.chapters[0]
    doc = renameChapter(doc, c.id, 'Porto')
    expect(doc.pages[1].items.map((i) => i.text)).toContain('Porto')
    doc = setBackground(doc, doc.pages[2].id, 'dark', true)
    expect(doc.pages.filter((p) => p.chapter === c.id).every((p) => p.background === 'dark')).toBe(true)
    doc = relayoutChapter(doc, c.id, a, f)
    expect(usedPhotoIDs(doc).size).toBe(5)
  })
})

describe('preflight', () => {
  it('passes a fresh book and blocks on low resolution or missing photos', () => {
    const a = batch(6)
    const doc = createDoc({ batches: [a], title: 'T', me: 'me' })
    expect(preflight(doc, byID(a)).blocked).toBe(false)
    const small = { ...a.photos[0], pixel_width: 600, pixel_height: 450 }
    expect(preflight(doc, { ...byID(a), [small.id]: small }).blocked).toBe(true)
    const { [a.photos[1].id]: _, ...missing } = byID(a)
    expect(preflight(doc, missing).problems.some((p) => p.text.includes('no longer shared'))).toBe(true)
  })
  it('warns when a photo crosses the safe line', () => {
    const a = batch(1)
    let doc = createDoc({ batches: [a], title: 'T', me: 'me' })
    const i = doc.pages.findIndex((p) => p.items.some((x) => x.kind === 'photo'))
    doc.pages[i].items[0] = { ...doc.pages[i].items[0], x: 0.05 }
    expect(preflight(doc, byID(a)).problems.some((p) => p.page === i && p.level === 'warn')).toBe(true)
    expect(safeMargin(f)).toBeCloseTo(0.046875)
    expect(aspectOf({})).toBe(1)
  })
})

describe('history', () => {
  it('undoes, redoes, and merges a drag into one step', () => {
    let h = start(1)
    h = push(h, 2, null, 0)
    h = push(h, 3, 'drag', 1000)
    h = push(h, 4, 'drag', 1200)
    expect(h.past).toEqual([1, 2])
    h = undo(h)
    expect(h.present).toBe(2)
    h = redo(h)
    expect(h.present).toBe(4)
    h = push(h, 5, 'drag', 5000)
    expect(h.past).toEqual([1, 2, 4])
  })
})

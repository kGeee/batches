// Page layouts from photo shapes. Every template places whole prints: a print's height always
// follows from its photo's aspect ratio and its frame, so nothing is ever cropped to fit.
import { aspectOf, gutter, printAspect, safeMargin } from './format.js'

let counter = 0
export const newID = (prefix) => `${prefix}${Date.now().toString(36)}${(counter++).toString(36)}${Math.random().toString(36).slice(2, 6)}`

/** The area photos are laid into: the safe area, pulled in a little so pages breathe. */
export const contentBox = (format) => {
  const m = safeMargin(format) + 0.02
  return { x: m, y: m, w: 1 - 2 * m, h: 1 - 2 * m }
}

/** Every way to split n photos into rows, in order: 3 → [3], [2,1], [1,2], [1,1,1]. */
export function compositions(n) {
  if (n === 0) return [[]]
  const out = []
  for (let k = 1; k <= n; k++) for (const rest of compositions(n - k)) out.push([k, ...rest])
  return out
}

/**
 * Prints in rows inside `box`. Each row spans the box's width at full size; if the rows are too
 * tall together, every print shrinks by the same amount and the block is centred. Returns the
 * placements and a score: how much of the box is used, and how evenly.
 */
export function rows(aspects, split, box) {
  let i = 0
  const specs = split.map((k) => {
    const as = aspects.slice(i, i + k)
    i += k
    return { as, h: (box.w - (k - 1) * gutter) / as.reduce((s, a) => s + a, 0) }
  })
  const sumH = specs.reduce((s, r) => s + r.h, 0)
  const gaps = (split.length - 1) * gutter
  const s = Math.min(1, (box.h - gaps) / sumH)
  let y = box.y + (box.h - (s * sumH + gaps)) / 2
  const placed = []
  for (const r of specs) {
    const h = r.h * s
    const rowW = r.as.reduce((t, a) => t + a * h, 0) + (r.as.length - 1) * gutter
    let x = box.x + (box.w - rowW) / 2
    for (const a of r.as) {
      const w = a * h
      placed.push({ x: x + w / 2, y: y + h / 2, w, h })
      x += w + gutter
    }
    y += h + gutter
  }
  const area = box.w * box.h
  const used = placed.reduce((t, p) => t + p.w * p.h, 0)
  const smallest = Math.min(...placed.map((p) => p.w * p.h))
  const fair = used / placed.length
  return { placed, score: (used / area) * (0.55 + 0.45 * Math.min(1, smallest / fair)) }
}

const splitTitles = {
  '1': 'One', '2': 'Side by side', '1,1': 'Stacked', '3': 'Row of three', '1,2': 'One over two',
  '2,1': 'Two over one', '1,1,1': 'Column', '2,2': 'Grid', '1,3': 'One over three', '3,1': 'Three over one',
}

/** Templates for these photos, best first. Each lists placements in photo order. */
export function templatesFor(photos, frames, format) {
  const n = photos.length
  if (!n) return []
  const box = contentBox(format)
  const aspects = photos.map((p, i) => printAspect(aspectOf(p), frames[i]))
  const splits = n <= 4 ? compositions(n) : [gridSplit(n)]
  return splits
    .map((split) => ({ id: `rows:${split.join(',')}`, title: splitTitles[split.join(',')] ?? split.join(' + '), ...rows(aspects, split, box) }))
    .sort((a, b) => b.score - a.score)
}

function gridSplit(n) {
  const perRow = Math.ceil(Math.sqrt(n))
  const out = []
  for (let left = n; left > 0; left -= perRow) out.push(Math.min(perRow, left))
  return out
}

/** A small hash of a string to 0…1, so a scatter looks the same every time. */
function unit(s, salt) {
  let h = 2166136261 ^ salt
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619)
  return ((h >>> 0) % 10000) / 10000
}

/** Prints laid down loosely by hand: a little apart, a little tilted. */
export function scatter(photos, frames, format) {
  const n = photos.length
  const w = n === 1 ? 0.62 : n === 2 ? 0.44 : n === 3 ? 0.4 : 0.34
  const cols = n <= 2 ? n : 2
  const rowsN = Math.ceil(n / cols)
  const box = contentBox(format)
  return photos.map((p, i) => {
    const c = i % cols, r = Math.floor(i / cols)
    const jx = (unit(p.id, 1) - 0.5) * 0.06, jy = (unit(p.id, 2) - 0.5) * 0.06
    const h = w / printAspect(aspectOf(p), frames[i])
    return {
      x: box.x + box.w * ((c + 0.5) / cols) + jx,
      y: box.y + box.h * ((r + 0.5) / rowsN) + jy,
      w: Math.min(w, (box.h / rowsN) * printAspect(aspectOf(p), frames[i]) * 1.05),
      h,
      rotation: Math.round((unit(p.id, 3) - 0.5) * 12),
    }
  })
}

/**
 * One photo across both pages of a spread, placed on the left page in left-page units (the
 * spread runs from 0 to 2). Only for a left-hand page.
 */
export function acrossSpread(photo, frame, format) {
  const m = safeMargin(format)
  const a = printAspect(aspectOf(photo), frame)
  const w = Math.min(2 - 2 * m, (1 - 2 * m) * a)
  return { x: 1, y: 0.5, w, h: w / a }
}

// Snapping -------------------------------------------------------------------------------------

/**
 * Where a dragged box lands on one axis. `c` is its centre and `h` half its size; it snaps when
 * its start, centre or end is within `tolerance` of a target. Returns how far to move and the
 * target lines it now touches.
 */
export function snapAxis(c, h, targets, tolerance) {
  let best = null
  for (const t of targets) {
    for (const p of [c - h, c, c + h]) {
      const d = t - p
      if (Math.abs(d) <= tolerance && (!best || Math.abs(d) < Math.abs(best))) best = d
    }
  }
  if (best === null) return { delta: 0, lines: [] }
  const at = [c - h + best, c + best, c + h + best]
  const lines = [...new Set(targets.filter((t) => at.some((p) => Math.abs(p - t) < 1e-6)))]
  return { delta: best, lines }
}

// Whole books ----------------------------------------------------------------------------------

/** How photos group onto pages: a hero to start, portraits in pairs, a rhythm of ones and twos. */
export function groupPhotos(photos) {
  const groups = []
  let i = 0
  while (i < photos.length) {
    const a = aspectOf(photos[i])
    const next = photos[i + 1]
    const nextA = next ? aspectOf(next) : null
    const lastWasSingle = groups.length > 0 && groups[groups.length - 1].length === 1
    if (a > 2.2 || groups.length === 0 || !next || nextA > 2.2) { groups.push([photos[i]]); i += 1; continue }
    if ((a < 0.95 && nextA < 0.95) || lastWasSingle) { groups.push([photos[i], next]); i += 2; continue }
    groups.push([photos[i]]); i += 1
  }
  return groups
}

const roman = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII']
export const numeral = (i) => roman[i] ?? String(i + 1)

/** Breaks a title into lines of about `max` characters at spaces. */
export function wrapTitle(text, max = 16) {
  const words = String(text).trim().split(/\s+/)
  const lines = []
  let line = ''
  for (const w of words) {
    if (line && (line + ' ' + w).length > max) { lines.push(line); line = w } else line = line ? `${line} ${w}` : w
  }
  if (line) lines.push(line)
  return lines.slice(0, 4)
}

const text = (t, x, y, size, font, extra = {}) => ({ id: newID('t'), kind: 'text', text: t, x, y, size, font, rotation: 0, z: 0, color: 'ink', italic: false, ...extra })

/** The page a chapter opens with: its number, its title in the batch's font, when and who. */
export function openerItems(chapter, index) {
  const lines = wrapTitle(chapter.title)
  const size = lines.length > 2 ? 0.062 : 0.074
  const top = 0.5 - ((lines.length - 1) * size * 1.15) / 2
  const items = [text(numeral(index), 0.5, top - 0.11, 0.05, chapter.font, { color: 'accent' })]
  lines.forEach((l, i) => items.push(text(l, 0.5, top + i * size * 1.15, size, chapter.font)))
  const after = top + (lines.length - 1) * size * 1.15
  if (chapter.subtitle) items.push(text(chapter.subtitle.toUpperCase(), 0.5, after + 0.1, 0.022, 'mono', { color: 'muted' }))
  if (chapter.credit) items.push(text(chapter.credit.toUpperCase(), 0.5, after + 0.14, 0.022, 'mono', { color: 'muted' }))
  return items
}

/** Page 1: the book's title and who's in it. */
export function titleItems(title, byline, font) {
  const lines = wrapTitle(title, 18)
  const size = 0.07
  const top = 0.46 - ((lines.length - 1) * size * 1.15) / 2
  const items = lines.map((l, i) => text(l, 0.5, top + i * size * 1.15, size, font))
  if (byline) items.push(text(byline.toUpperCase(), 0.5, top + (lines.length - 1) * size * 1.15 + 0.11, 0.022, 'mono', { color: 'muted' }))
  return items
}

/** Photo items for a template's placements. */
export function photoItems(photos, frames, placed, base = {}) {
  return photos.map((p, i) => ({
    id: newID('i'), kind: 'photo', photo: p.id, aspect: aspectOf(p), frame: frames[i],
    x: placed[i].x, y: placed[i].y, w: placed[i].w, rotation: placed[i].rotation ?? 0, z: i, ...base,
  }))
}

/** A page of photos laid out with its best template. */
export function photoPage(photos, frames, chapter, format) {
  const best = templatesFor(photos, frames, format)[0]
  return { id: newID('p'), chapter: chapter?.id ?? null, background: chapter?.background ?? 'paper', layout: best.id, items: photoItems(photos, frames, best.placed) }
}

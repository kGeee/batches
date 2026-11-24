// What a printed book is physically, and the geometry every view shares.
//
// Positions in a book are in page units: 1 is the width of a trimmed page. The square book is as
// tall as it is wide, so y uses the same unit. The editor, the thumbnails and the print renderer
// all size things through the functions here, so what's arranged on screen is what prints.

export const formats = {
  square8: {
    id: 'square8',
    title: 'Square',
    detail: '8 × 8 in hardcover',
    trimInches: 8,
    // Gelato asks for 3 mm past the trim on every side of a photo book page and anything important
    // at least 4 mm inside it; we keep it 3/8 in inside.
    bleedInches: 3 / 25.4,
    safeInches: 0.375,
    // Gelato's photo books run from 30 to 200 pages.
    minPages: 30,
    maxPages: 120,
    priceCents: 3900,
    extraPageCents: 100,
    shippingCents: 600,
  },
}
export const defaultFormat = 'square8'
export const formatOf = (doc) => formats[doc?.format] ?? formats[defaultFormat]

/** Margin inside which anything important stays, in page units. */
export const safeMargin = (format) => format.safeInches / format.trimInches
export const bleed = (format) => format.bleedInches / format.trimInches
/** Room between photos in a template. */
export const gutter = 0.03

/** Rounded up to an even count, and to the format's minimum. */
export function evenPages(n, format) {
  const even = Math.max(format.minPages, n + (n % 2))
  return Math.min(format.maxPages, even)
}

export const priceCents = (format, pages) => format.priceCents + Math.max(0, pages - format.minPages) * format.extraPageCents
export const money = (cents) => `$${(cents / 100).toFixed(cents % 100 ? 2 : 0)}`

// Prints ---------------------------------------------------------------------------------------

export const aspectOf = (photo) => (photo?.pixel_width > 0 && photo?.pixel_height > 0 ? photo.pixel_width / photo.pixel_height : 1)

/** The book's frames, from the app's FrameStyle kinds. A roll of film prints as a thin black edge. */
export const frameKinds = ['none', 'whiteBorder', 'polaroid', 'galleryMat', 'thinBlack']
export const frameTitles = { none: 'None', whiteBorder: 'Border', polaroid: 'Instant', galleryMat: 'Mat', thinBlack: 'Black edge' }
export function bookFrame(kind) {
  if (kind === 'filmStrip') return 'thinBlack'
  return frameKinds.includes(kind) ? kind : 'whiteBorder'
}

/**
 * Padding a frame adds around the photo, as fractions of the print's width: [top, right, bottom,
 * left]. Proportional, so a small instant print has a small margin, as a real one does.
 */
export function framePadding(kind) {
  switch (kind) {
    case 'none': return [0, 0, 0, 0]
    case 'thinBlack': return [0.012, 0.012, 0.012, 0.012]
    case 'polaroid': return [0.06, 0.06, 0.2, 0.06]
    case 'galleryMat': return [0.11, 0.11, 0.11, 0.11]
    default: return [0.045, 0.045, 0.045, 0.045]
  }
}

/** A print's width ÷ height, frame included. Photos keep their own shape inside it. */
export function printAspect(photoAspect, kind) {
  const [t, r, b, l] = framePadding(kind)
  return 1 / ((1 - l - r) / photoAspect + t + b)
}

/**
 * Everything about one placed print, in page units: its size, its frame and where the photo sits
 * inside it. `w` is the print's width, frame included; the height always follows from the
 * photo's shape, so a photo can't be stretched or cut.
 */
export function printBox(item, photoAspect, kind) {
  const [t, r, b, l] = framePadding(kind).map((f) => f * item.w)
  const imageW = item.w - l - r
  const imageH = imageW / photoAspect
  return { w: item.w, h: imageH + t + b, imageW, imageH, pad: [t, r, b, l] }
}

/** The page-unit rectangle a turned box covers, for checking margins. */
export function turnedBounds(cx, cy, w, h, degrees) {
  const a = (degrees * Math.PI) / 180
  const c = Math.abs(Math.cos(a)), s = Math.abs(Math.sin(a))
  const bw = w * c + h * s, bh = w * s + h * c
  return { left: cx - bw / 2, right: cx + bw / 2, top: cy - bh / 2, bottom: cy + bh / 2 }
}

/** The largest shared copy is 1800 px on its long edge. */
export const largestCopyEdge = 1800

/** Pixels across the largest copy we can print from. */
export function printablePixelsAcross(photo) {
  const long = Math.max(photo.pixel_width, photo.pixel_height)
  return photo.pixel_width * Math.min(1, largestCopyEdge / long)
}

/** Dots per inch a photo prints at with this width in page units. */
export function effectiveDPI(photo, imageWidthUnits, format) {
  return printablePixelsAcross(photo) / (imageWidthUnits * format.trimInches)
}
export const dpiGood = 200
export const dpiLowest = 150

// Text -----------------------------------------------------------------------------------------

/** Line height for a text item, as a multiple of its size. */
export const lineHeight = 1.15

// Cover ----------------------------------------------------------------------------------------

/** Where things sit on the front cover, in units of its width. The photo keeps its own shape. */
export const coverLayout = { photoMaxW: 0.6, photoMaxH: 0.58, photoCenterY: 0.42, titleY: 0.8, titleSize: 0.058, bylineY: 0.875, bylineSize: 0.022 }
export function coverPhotoBox(aspect) {
  const w = Math.min(coverLayout.photoMaxW, coverLayout.photoMaxH * aspect)
  return { w, h: w / aspect, x: 0.5, y: coverLayout.photoCenterY }
}
/** Spine width in inches: thicker with more pages. Only an estimate; the printer's own measurements win. */
export const spineInches = (pages) => 0.25 + pages * 0.0025

const mm = (v) => v / 25.4

/**
 * The cover as one flat sheet, in inches: the sheet's size, and where the back, spine and front sit
 * on it (each `{ x, y, w, h }` from the sheet's top left). `printer` is Gelato's cover-dimensions
 * answer for this page count; with it the sheet is exactly what Gelato prints. Without it the
 * sheet is estimated from Gelato's published hardcover example (a 17 mm wrap round the boards, a
 * 3 mm board edge and 8 mm hinges either side of the spine), good for a preview but not for print.
 */
export function coverSheet(format, pages, printer = null) {
  const exact = printer && sheetFromPrinter(printer)
  if (exact) return exact
  const trim = format.trimInches
  const edge = mm(17 + 3), joint = mm(8), spine = spineInches(pages)
  const back = { x: edge, y: edge, w: trim, h: trim }
  const spineBox = { x: edge + trim + joint, y: edge, w: spine, h: trim }
  const front = { x: spineBox.x + spine + joint, y: edge, w: trim, h: trim }
  return { w: front.x + trim + edge, h: trim + 2 * edge, back, spine: spineBox, front, estimate: true }
}

/** Gelato's cover-dimensions answer (millimetres) as a cover sheet in inches, or null if it doesn't add up. */
export function sheetFromPrinter(d) {
  if (!d || (d.measureUnit && d.measureUnit !== 'mm')) return null
  const box = (a) => (a && [a.left ?? 0, a.top ?? 0, a.width, a.height].every((v) => Number.isFinite(v) && v >= 0)
    ? { x: mm(a.left ?? 0), y: mm(a.top ?? 0), w: mm(a.width), h: mm(a.height) } : null)
  const back = box(d.contentBackSize), spine = box(d.spineSize), front = box(d.contentFrontSize)
  if (!back || !spine || !front || !back.w || !front.w) return null
  // Hardcover: the wraparound is the whole sheet. Softcover: the bleed area is, or else the content's edges.
  const outer = box(d.wraparoundInsideSize) ?? box(d.bleedSize)
  const w = outer ? outer.x + outer.w : front.x + front.w
  const h = outer ? outer.y + outer.h : Math.max(back.y + back.h, front.y + front.h)
  if (!(w >= front.x + front.w) || !(h >= front.y + front.h)) return null
  return { w, h, back, spine, front, estimate: false }
}

// Pages and spreads ----------------------------------------------------------------------------

/**
 * Pages as they face each other. Page 1 is a right-hand page facing the inside of the cover, and
 * the last page faces the inside of the back cover. Each spread is [left, right], either side
 * possibly null.
 */
export function spreadsOf(pages) {
  const out = [[null, pages[0] ?? null]]
  for (let i = 1; i < pages.length; i += 2) out.push([pages[i], pages[i + 1] ?? null])
  return out
}
/** Index of the spread a page is on. */
export const spreadIndexOf = (pageIndex) => (pageIndex === 0 ? 0 : Math.floor((pageIndex - 1) / 2) + 1)
/** Page 1 and every odd page is on the right. */
export const isLeftPage = (pageIndex) => pageIndex % 2 === 1

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
    // Printers ask for 1/8 in past the trim on every side, and keep anything important 3/8 in inside it.
    bleedInches: 0.125,
    safeInches: 0.375,
    minPages: 20,
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
/** Spine width in inches: thicker with more pages. */
export const spineInches = (pages) => 0.25 + pages * 0.0025

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

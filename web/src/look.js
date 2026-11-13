// How a batch looks, ported from the iOS app so a batch reads the same on the web:
// Strewn/Models/BatchLook.swift, FrameStyle.swift, Features/Gallery/PhotoFrame.swift and
// Features/DeskPile/PileLayout.swift. Sizes are in CSS pixels where the app uses points.

// Fonts ------------------------------------------------------------------------------------------
// Every face the app uses ships with iOS and macOS. Elsewhere the nearest common face stands in.

const serif = '"New York", ui-serif, "Iowan Old Style", Georgia, serif'
export const fonts = {
  classic: serif,
  modern: '-apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", Roboto, sans-serif',
  rounded: 'ui-rounded, "SF Pro Rounded", "Arial Rounded MT Bold", "Nunito", system-ui, sans-serif',
  typewriter: '"American Typewriter", "Courier Prime", "Courier New", monospace',
  didot: 'Didot, "Bodoni 72", "Bodoni MT", "Playfair Display", serif',
  futura: 'Futura, "Century Gothic", "Avenir Next", "Trebuchet MS", sans-serif',
  handwritten: 'Noteworthy, "Bradley Hand", "Segoe Print", "Comic Sans MS", cursive',
}
export const fontFamily = (font) => fonts[font] ?? fonts.classic
// Polaroid captions are handwritten unless the batch picked a font.
export const captionFamily = (font) => fonts[font] ?? '"Bradley Hand", Noteworthy, "Segoe Print", cursive'

// Backgrounds ------------------------------------------------------------------------------------

const presets = {
  light: { color: '#f3f3f3', scheme: 'light' },
  dark: { color: '#121212', scheme: 'dark' },
  desk: { color: null, scheme: null },            // linen, following the system
  kraft: { color: '#ccb087', scheme: 'light', neutral: true },
}

/**
 * What a batch's photos sit on: collections.background, else the frame's wall. A roll of film is
 * always on a dark wall. `scheme` is the text colour the background needs (null follows the
 * system); `neutral` means amber controls would disappear into it.
 */
export function backdrop(batch) {
  if (batch.frame?.kind === 'filmStrip') return { key: 'dark', ...presets.dark }
  const raw = batch.background ?? batch.frame?.wall ?? 'light'
  if (presets[raw]) return { key: raw, ...presets[raw] }
  if (/^#[0-9a-f]{6}$/.test(raw)) {
    const v = parseInt(raw.slice(1), 16)
    const [r, g, b] = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((c) => c / 255)
    const light = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
    return { key: 'custom', color: raw, scheme: light ? 'light' : 'dark', neutral: true }
  }
  return { key: 'light', ...presets.light }
}

// Frames -----------------------------------------------------------------------------------------

export const defaultFrame = { kind: 'whiteBorder', borderWidth: 14, wall: 'light', layout: 'single' }

/** Padding the frame adds around the photo: [top, right, bottom, left]. */
export function insets(frame) {
  const w = frame.borderWidth ?? 14
  switch (frame.kind) {
    case 'none': return [0, 0, 0, 0]
    case 'thinBlack': return [w * 0.25, w * 0.25, w * 0.25, w * 0.25]
    case 'polaroid': return [w, w, w * 3.6 + 6, w]
    case 'filmStrip': return [w * 1.5 + 12, 8, w * 1.5 + 12, 8]
    case 'galleryMat': return [w * 1.8, w * 1.8, w * 1.8, w * 1.8]
    default: return [w, w, w, w]
  }
}

// Desk piles -------------------------------------------------------------------------------------

/** SplitMix64 seeded from a UUID's first eight bytes, as the app does, so piles match it. */
function seeded(uuid) {
  let state = BigInt('0x' + uuid.replace(/-/g, '').slice(0, 16))
  const mask = (1n << 64n) - 1n
  const nextUInt = () => {
    state = (state + 0x9E3779B97F4A7C15n) & mask
    let z = state
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & mask
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & mask
    return z ^ (z >> 31n)
  }
  return (lo, hi) => lo + (Number(nextUInt() >> 11n) / 2 ** 53) * (hi - lo)
}

export function orientation(photo) {
  const r = photo.pixel_height > 0 ? photo.pixel_width / photo.pixel_height : 1
  return r < 0.95 ? 'portrait' : r <= 1.05 ? 'square' : r < 2.2 ? 'landscape' : 'panorama'
}

/** Where a print lands in a pile: straight unless the desk's owner turned tilting on. */
export function pilePlacement(photo, isTop, tilted) {
  const next = seeded(photo.id)
  const width = { portrait: 0.44, square: 0.52, landscape: 0.62, panorama: 0.8 }[orientation(photo)]
  if (!tilted) {
    if (isTop) return { angle: 0, x: 0, y: 0, width }
    return { angle: 0, x: next(-0.05, 0.05), y: next(-0.06, 0.06), width }
  }
  if (isTop) return { angle: next(-4, 4), x: next(-0.015, 0.015), y: next(-0.015, 0.015), width }
  return { angle: next(-17, 17), x: next(-0.09, 0.09), y: next(-0.07, 0.07), width }
}

export const cover = (batch) => batch.photos.find((p) => p.id === batch.cover_photo_id) ?? batch.photos[0]

/** Up to `limit` photos for the pile, bottom first, cover on top. */
export function pileStack(batch, limit = 5) {
  const top = cover(batch)
  if (!top) return []
  return [...batch.photos.filter((p) => p.id !== top.id).slice(0, limit - 1), top]
}

// Freehand boards --------------------------------------------------------------------------------
// Placements are fractions of the board's width, so the arrangement looks the same at any width.

const margin = 0.03
const widths = [0.22, 1]
const rotations = [-30, 30]
const clamp = (v, [lo, hi]) => Math.min(hi, Math.max(lo, v))
const aspect = (p) => (p.pixel_height > 0 ? p.pixel_width / p.pixel_height : 1)
const finite = (v, d) => (typeof v === 'number' && Number.isFinite(v) ? v : d)

/** A board from someone else's phone, held to what the app's editor can make. */
function sane(place) {
  return {
    x: clamp(finite(place.x, 0.5), [0, 1]), y: clamp(finite(place.y, 0), [0, 200]),
    width: clamp(finite(place.width, 0.46), widths), rotation: clamp(finite(place.rotation, 0), rotations),
    z: Math.round(finite(place.z, 0)),
  }
}

function printSize(photo, place, ins, boardWidth) {
  const [t, r, b, l] = ins
  const image = Math.max(20, place.width * boardWidth - l - r)
  return { width: image + l + r, height: image / aspect(photo) + t + b, image }
}

/** How much room the turned print takes, as fractions of the board's width. */
function bounds(photo, place, ins, boardWidth) {
  const s = printSize(photo, place, ins, boardWidth)
  const a = (place.rotation * Math.PI) / 180
  const c = Math.abs(Math.cos(a)), n = Math.abs(Math.sin(a))
  return { width: (s.width * c + s.height * n) / boardWidth, height: (s.width * n + s.height * c) / boardWidth }
}

function tidy(photos, ins, boardWidth, top = margin, z = 0) {
  const bottoms = [top, top]
  const result = {}
  photos.forEach((photo, i) => {
    const column = bottoms[0] <= bottoms[1] ? 0 : 1
    const place = { x: column === 0 ? 0.26 : 0.74, y: 0, width: 0.46, rotation: 0, z: z + i }
    const box = bounds(photo, place, ins, boardWidth)
    place.y = bottoms[column] + box.height / 2
    bottoms[column] += box.height + margin
    result[photo.id] = place
  })
  return result
}

/**
 * Every photo's place on the board, its size in pixels and the board's height. Photos without a
 * saved place (a friend just added them) go below the rest, as in the app.
 */
export function boardLayout(batch, boardWidth) {
  const ins = insets(batch.frame)
  const saved = batch.board?.placements ?? {}
  const places = {}
  const unplaced = []
  for (const photo of batch.photos) {
    const p = saved[photo.id.toLowerCase()]
    if (p && typeof p === 'object') places[photo.id] = sane(p)
    else unplaced.push(photo)
  }
  const placed = batch.photos.filter((p) => places[p.id])
  if (unplaced.length) {
    const bottom = placed.length
      ? Math.max(...placed.map((p) => places[p.id].y + bounds(p, places[p.id], ins, boardWidth).height / 2))
      : margin
    const topZ = Math.max(0, ...Object.values(places).map((p) => p.z)) + 1
    Object.assign(places, tidy(unplaced, ins, boardWidth, bottom + (placed.length ? margin : 0), topZ))
  }
  const bottom = Math.max(0, ...batch.photos.map((p) => places[p.id].y + bounds(p, places[p.id], ins, boardWidth).height / 2))
  const items = batch.photos.map((photo, index) => {
    const place = places[photo.id]
    return { photo, index, place, imageWidth: printSize(photo, place, ins, boardWidth).image }
  })
  return { items, height: (bottom + margin) * boardWidth }
}

export const showsBoard = (batch) => batch.board?.isOn === true && batch.frame?.kind !== 'filmStrip'

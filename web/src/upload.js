// Preparing photos in the browser for Batches:
//   - Full frame, always: every copy keeps the photo's native aspect ratio; nothing is cropped.
//   - Same ladder as Strewn/Services/ShareCopyMaker.swift: s (320), m (800), l (1800) on the long
//     edge, 1.6x for panoramas wider than 2.2:1, and never upscaled.
//   - Location and other metadata stay out of shared copies (drawing to canvas keeps only pixels),
//     while capture date and camera EXIF are read beforehand for the photo row.
import { parseExif } from './exif.js'
import { decodeHEIC, detectImageMime, heicSupported, tierEdges } from './photos.js'

export const MAX_BATCH_PHOTOS = 60
export const MAX_COPY_BYTES = 5 * 1024 * 1024   // storage.buckets.file_size_limit for `media`

const tierQuality = { s: 0.78, m: 0.82, l: 0.85 }
const imageExt = /\.(jpe?g|png|webp|heic|heif|avif|gif|bmp|tiff?)$/i
const heicExt = /\.(heic|heif)$/i

export function isSupportedImageFile(file) {
  if (!file) return false
  if (typeof file.type === 'string' && file.type.startsWith('image/')) return true
  return typeof file.name === 'string' && imageExt.test(file.name)
}

/**
 * Target pixel size for one shared-copy tier, preserving the photo's native aspect ratio and never
 * upscaling, matching ShareCopyMaker.swift.
 */
export function tierDimensions(pixelWidth, pixelHeight, tier) {
  const w = Math.max(1, Math.round(pixelWidth || 1))
  const h = Math.max(1, Math.round(pixelHeight || 1))
  const longSide = Math.max(w, h)
  const shortSide = Math.min(w, h)
  const isPanorama = shortSide > 0 && longSide / shortSide > 2.2
  const edge = Math.round((tierEdges[tier] ?? tierEdges.l) * (isPanorama ? 1.6 : 1))
  const targetLong = Math.min(edge, longSide)
  const scale = targetLong / longSide
  return {
    width: Math.max(1, Math.round(w * scale)),
    height: Math.max(1, Math.round(h * scale)),
  }
}

/** Merges parsed EXIF with optional metadata (e.g. from Google Photos Picker API). */
export function mergePhotoMeta(parsed, fallback = {}) {
  const capturedAt = parsed?.capturedAt ?? fallback?.capturedAt ?? null
  const exif = { ...(fallback?.exif ?? {}), ...(parsed?.exif ?? {}) }
  const cleanExif = Object.keys(exif).length ? exif : null
  return { capturedAt, exif: cleanExif }
}

async function normalizeDecodeBlob(file) {
  const head = new Uint8Array(await file.slice(0, 16).arrayBuffer())
  const mime = detectImageMime(head) || file.type || ''
  const isHEIC = mime === 'image/heic' || mime === 'image/heif' || (!mime && heicExt.test(file.name ?? ''))
  if (isHEIC && !(await heicSupported())) {
    return decodeHEIC(file)
  }
  return mime && file.type !== mime ? new Blob([file], { type: mime }) : file
}

async function decodeOrientedImage(blob) {
  if (typeof createImageBitmap === 'function') {
    try {
      const bmp = await createImageBitmap(blob, { imageOrientation: 'from-image' })
      return { source: bmp, width: bmp.width, height: bmp.height, close: () => bmp.close?.() }
    } catch {
      // Fall back to <img> when createImageBitmap doesn't support this container.
    }
  }
  const url = URL.createObjectURL(blob)
  try {
    const img = await new Promise((resolve, reject) => {
      const el = new Image()
      el.onload = () => resolve(el)
      el.onerror = () => reject(new Error('This image could not be decoded.'))
      el.src = url
    })
    return {
      source: img,
      width: img.naturalWidth || img.width,
      height: img.naturalHeight || img.height,
      close: () => URL.revokeObjectURL(url),
    }
  } catch (err) {
    URL.revokeObjectURL(url)
    throw err
  }
}

function makeCanvas(width, height) {
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  return canvas
}

function drawScaled(source, width, height) {
  const canvas = makeCanvas(width, height)
  const ctx = canvas.getContext('2d')
  ctx.imageSmoothingEnabled = true
  if ('imageSmoothingQuality' in ctx) ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(source, 0, 0, width, height)
  return canvas
}

function canvasToJpeg(canvas, quality) {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error('Could not encode JPEG copy.'))),
      'image/jpeg',
      quality,
    )
  })
}

async function encodeWithinLimit(canvas, startQuality) {
  let q = startQuality
  let blob = await canvasToJpeg(canvas, q)
  while (blob.size > MAX_COPY_BYTES - 65536 && q > 0.45) {
    q = Math.round((q - 0.12) * 100) / 100
    blob = await canvasToJpeg(canvas, q)
  }
  if (blob.size > MAX_COPY_BYTES) {
    throw new Error('Photo copy is still larger than the 5 MB limit.')
  }
  return blob
}

/**
 * Reads a File's dimensions, EXIF and small full-frame preview so the picker shows prints in their
 * real proportions right away without keeping decoded full-res bitmaps in memory.
 */
export async function preparePhotoFile(file, fallbackMeta = {}) {
  if (!isSupportedImageFile(file)) {
    throw new Error(`“${file?.name || 'File'}” isn't a supported photo.`)
  }
  const headerSlice = await file.slice(0, Math.min(file.size, 512 * 1024)).arrayBuffer()
  const parsed = parseExif(headerSlice)
  const meta = mergePhotoMeta(parsed, fallbackMeta)

  const decodable = await normalizeDecodeBlob(file)
  const decoded = await decodeOrientedImage(decodable)
  try {
    const { width, height } = decoded
    if (!width || !height) throw new Error(`Couldn't read dimensions of “${file.name || 'photo'}”.`)
    const thumbDims = tierDimensions(width, height, 's')
    const thumbCanvas = drawScaled(decoded.source, thumbDims.width, thumbDims.height)
    const previewBlob = await canvasToJpeg(thumbCanvas, 0.8)
    const previewURL = URL.createObjectURL(previewBlob)
    return {
      localID: crypto.randomUUID(),
      file,
      decodable,
      name: file.name || 'Photo',
      pixelWidth: width,
      pixelHeight: height,
      caption: '',
      capturedAt: meta.capturedAt,
      exif: meta.exif,
      previewURL,
      sourceKind: fallbackMeta.sourceKind || 'device',
    }
  } finally {
    decoded.close()
  }
}

/** Releases a prepared item's preview blob URL when removed or closed. */
export function releasePreparedPhoto(item) {
  if (item?.previewURL) {
    try { URL.revokeObjectURL(item.previewURL) } catch { /* ignore */ }
  }
}

/**
 * Renders the s, m and l JPEG shared copies from a prepared photo item. Steps down progressively
 * (full -> l -> m -> s) so thumbnails stay crisp and the full-res bitmap is decoded only once.
 */
export async function renderShareCopies(item) {
  const blob = item.decodable ?? await normalizeDecodeBlob(item.file)
  const decoded = await decodeOrientedImage(blob)
  try {
    const lDims = tierDimensions(decoded.width, decoded.height, 'l')
    const mDims = tierDimensions(decoded.width, decoded.height, 'm')
    const sDims = tierDimensions(decoded.width, decoded.height, 's')

    const lCanvas = drawScaled(decoded.source, lDims.width, lDims.height)
    const mCanvas = drawScaled(lCanvas, mDims.width, mDims.height)
    const sCanvas = drawScaled(mCanvas, sDims.width, sDims.height)

    const [s, m, l] = await Promise.all([
      encodeWithinLimit(sCanvas, tierQuality.s),
      encodeWithinLimit(mCanvas, tierQuality.m),
      encodeWithinLimit(lCanvas, tierQuality.l),
    ])

    return {
      pixelWidth: decoded.width,
      pixelHeight: decoded.height,
      copies: { s, m, l },
    }
  } finally {
    decoded.close()
  }
}

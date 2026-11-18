// Reads camera EXIF and capture time straight from an uploaded image's bytes before canvas
// re-encoding strips GPS and all other metadata. Matches Strewn/Features/NewPile/NewPileSheet.swift
// (PhotoImport.metadata) so web-uploaded photos carry the same aperture, shutter, ISO, focal
// length and capture timestamp as iPhone imports.

const TAG_ORIENTATION = 0x0112
const TAG_DATETIME = 0x0132
const TAG_EXIF_IFD = 0x8769
const TAG_EXPOSURE_TIME = 0x829a
const TAG_FNUMBER = 0x829d
const TAG_ISO = 0x8827
const TAG_DATETIME_ORIGINAL = 0x9003
const TAG_DATETIME_DIGITIZED = 0x9004
const TAG_OFFSET_ORIGINAL = 0x9010
const TAG_FOCAL_LENGTH = 0x920a
const TAG_FOCAL_35MM = 0xa405

const TYPE_SIZES = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8 }

/** Formats exposure seconds as "1/250", "2s" or "1.5s", matching PhotoImport.formatShutter. */
export function formatShutter(seconds) {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return null
  if (seconds >= 1) {
    const rounded = Math.round(seconds * 10) / 10
    return Number.isInteger(rounded) ? `${rounded}s` : `${rounded.toFixed(1)}s`
  }
  const denom = Math.round(1 / seconds)
  return denom > 0 ? `1/${denom}` : null
}

/** Parses a protobuf Duration string like "0.004s" or "1.5s" from Google Photos Picker API. */
export function parseDurationSeconds(value) {
  if (typeof value === 'number') return Number.isFinite(value) && value > 0 ? value : null
  if (typeof value !== 'string') return null
  const m = value.trim().match(/^(\d+(?:\.\d+)?)s$/)
  if (!m) return null
  const n = parseFloat(m[1])
  return Number.isFinite(n) && n > 0 ? n : null
}

/** Parses EXIF "YYYY:MM:DD HH:MM:SS" (+ optional "+HH:MM" offset) into an ISO timestamp. */
export function parseExifDate(raw, offset) {
  if (typeof raw !== 'string') return null
  const m = raw.trim().replace(/\0+$/, '').match(/^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/)
  if (!m) return null
  const [, y, mo, d, h, mi, s] = m
  if (+mo < 1 || +mo > 12 || +d < 1 || +d > 31) return null
  const cleanOffset = typeof offset === 'string' && /^[+-]\d{2}:\d{2}$/.test(offset.trim().replace(/\0+$/, ''))
    ? offset.trim().replace(/\0+$/, '')
    : ''
  const isoCandidate = cleanOffset
    ? `${y}-${mo}-${d}T${h}:${mi}:${s}${cleanOffset}`
    : `${y}-${mo}-${d}T${h}:${mi}:${s}`
  const parsed = new Date(isoCandidate)
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString()
}

function readTagValue(view, tiffStart, little, type, count, valueOffset) {
  const unit = TYPE_SIZES[type]
  if (!unit || count <= 0) return undefined
  const byteLen = unit * count
  const pos = byteLen <= 4 ? valueOffset : tiffStart + view.getUint32(valueOffset, little)
  if (pos < tiffStart || pos + byteLen > view.byteLength) return undefined

  if (type === 2) {
    let str = ''
    for (let i = 0; i < count; i++) {
      const ch = view.getUint8(pos + i)
      if (ch === 0) break
      str += String.fromCharCode(ch)
    }
    return str.trim()
  }
  const one = (i) => {
    const p = pos + i * unit
    switch (type) {
      case 1: case 7: return view.getUint8(p)
      case 3: return view.getUint16(p, little)
      case 4: return view.getUint32(p, little)
      case 9: return view.getInt32(p, little)
      case 5: {
        const num = view.getUint32(p, little)
        const den = view.getUint32(p + 4, little)
        return den ? num / den : undefined
      }
      case 10: {
        const num = view.getInt32(p, little)
        const den = view.getInt32(p + 4, little)
        return den ? num / den : undefined
      }
      default: return undefined
    }
  }
  return count === 1 ? one(0) : Array.from({ length: Math.min(count, 8) }, (_, i) => one(i))
}

function readIFD(view, tiffStart, ifdOffset, little) {
  const tags = new Map()
  if (ifdOffset < 8 || tiffStart + ifdOffset + 2 > view.byteLength) return tags
  const entries = view.getUint16(tiffStart + ifdOffset, little)
  for (let i = 0; i < entries; i++) {
    const entry = tiffStart + ifdOffset + 2 + i * 12
    if (entry + 12 > view.byteLength) break
    const tag = view.getUint16(entry, little)
    const type = view.getUint16(entry + 2, little)
    const count = view.getUint32(entry + 4, little)
    const val = readTagValue(view, tiffStart, little, type, count, entry + 8)
    if (val !== undefined) tags.set(tag, val)
  }
  return tags
}

function parseTiff(view, tiffStart) {
  if (tiffStart < 0 || tiffStart + 8 > view.byteLength) return null
  const bom = view.getUint16(tiffStart, false)
  const little = bom === 0x4949 ? true : bom === 0x4d4d ? false : null
  if (little === null) return null
  if (view.getUint16(tiffStart + 2, little) !== 0x002a) return null
  const ifd0Offset = view.getUint32(tiffStart + 4, little)
  const ifd0 = readIFD(view, tiffStart, ifd0Offset, little)
  const exifPtr = ifd0.get(TAG_EXIF_IFD)
  const exifIFD = typeof exifPtr === 'number' ? readIFD(view, tiffStart, exifPtr, little) : new Map()

  const orientation = typeof ifd0.get(TAG_ORIENTATION) === 'number' ? ifd0.get(TAG_ORIENTATION) : 1
  const offsetStr = exifIFD.get(TAG_OFFSET_ORIGINAL)
  const capturedAt = parseExifDate(exifIFD.get(TAG_DATETIME_ORIGINAL), offsetStr)
    ?? parseExifDate(exifIFD.get(TAG_DATETIME_DIGITIZED), offsetStr)
    ?? parseExifDate(ifd0.get(TAG_DATETIME))

  const rawAperture = exifIFD.get(TAG_FNUMBER)
  const aperture = typeof rawAperture === 'number' && rawAperture > 0
    ? Math.round(rawAperture * 100) / 100
    : undefined

  const exposure = exifIFD.get(TAG_EXPOSURE_TIME)
  const shutter = typeof exposure === 'number' ? (formatShutter(exposure) ?? undefined) : undefined

  const rawISO = exifIFD.get(TAG_ISO)
  const isoVal = Array.isArray(rawISO) ? rawISO[0] : rawISO
  const iso = typeof isoVal === 'number' && isoVal > 0 ? Math.round(isoVal) : undefined

  const focal35 = exifIFD.get(TAG_FOCAL_35MM)
  const focalRaw = exifIFD.get(TAG_FOCAL_LENGTH)
  const focalLength = typeof focal35 === 'number' && focal35 > 0
    ? Math.round(focal35)
    : typeof focalRaw === 'number' && focalRaw > 0
      ? Math.round(focalRaw)
      : undefined

  const exif = (aperture !== undefined || shutter !== undefined || iso !== undefined || focalLength !== undefined)
    ? {
        ...(aperture !== undefined ? { aperture } : {}),
        ...(shutter !== undefined ? { shutter } : {}),
        ...(iso !== undefined ? { iso } : {}),
        ...(focalLength !== undefined ? { focalLength } : {}),
      }
    : null

  return { orientation, capturedAt, exif }
}

/** Finds a TIFF header inside JPEG APP1, raw TIFF, or HEIC/ISOBMFF Exif payloads. */
function findTiffOffset(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (view.byteLength < 12) return -1

  // Raw TIFF
  const first2 = view.getUint16(0, false)
  if ((first2 === 0x4949 && view.getUint16(2, true) === 0x002a)
      || (first2 === 0x4d4d && view.getUint16(2, false) === 0x002a)) {
    return 0
  }

  // JPEG APP1 ("Exif\0\0")
  if (first2 === 0xffd8) {
    let pos = 2
    while (pos + 4 <= view.byteLength) {
      if (view.getUint8(pos) !== 0xff) break
      const marker = view.getUint8(pos + 1)
      if (marker === 0xda || marker === 0xd9) break
      const segLen = view.getUint16(pos + 2, false)
      if (segLen < 2 || pos + 2 + segLen > view.byteLength) break
      if (marker === 0xe1 && segLen >= 14
          && view.getUint32(pos + 4, false) === 0x45786966
          && view.getUint16(pos + 8, false) === 0x0000) {
        return pos + 10
      }
      pos += 2 + segLen
    }
    return -1
  }

  // ISOBMFF / HEIC: scan the header portion for an embedded "Exif\0\0II*" or "Exif\0\0MM\0*" block.
  if (view.getUint32(4, false) === 0x66747970) {
    const limit = Math.min(view.byteLength - 14, 512 * 1024)
    for (let i = 12; i < limit; i++) {
      if (bytes[i] === 0x45 && bytes[i + 1] === 0x78 && bytes[i + 2] === 0x69 && bytes[i + 3] === 0x66
          && bytes[i + 4] === 0x00 && bytes[i + 5] === 0x00) {
        const b0 = bytes[i + 6], b1 = bytes[i + 7]
        if ((b0 === 0x49 && b1 === 0x49 && bytes[i + 8] === 0x2a && bytes[i + 9] === 0x00)
            || (b0 === 0x4d && b1 === 0x4d && bytes[i + 8] === 0x00 && bytes[i + 9] === 0x2a)) {
          return i + 6
        }
      }
    }
  }

  return -1
}

/** Extracts { orientation, capturedAt, exif } from an ArrayBuffer or Uint8Array. */
export function parseExif(input) {
  const empty = { orientation: 1, capturedAt: null, exif: null }
  if (!input) return empty
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input)
  const tiffOffset = findTiffOffset(bytes)
  if (tiffOffset < 0) return empty
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  return parseTiff(view, tiffOffset) ?? empty
}

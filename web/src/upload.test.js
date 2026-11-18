import { describe, expect, it, vi } from 'vitest'
import { legacyWallFor } from './api.js'
import { formatShutter, parseDurationSeconds, parseExif, parseExifDate } from './exif.js'
import {
  createPickerSession,
  downloadGoogleMediaFile,
  extractGoogleMediaMeta,
  fullFrameDownloadUrl,
  listPickedMediaItems,
  normalizePickerUri,
  parsePollIntervalMs,
} from './googlePhotos.js'
import { detectImageMime } from './photos.js'
import { isSupportedImageFile, mergePhotoMeta, tierDimensions } from './upload.js'

/** Builds a minimal JPEG with an APP1 Exif segment carrying IFD0 + ExifIFD tags. */
function makeExifJpeg({ littleEndian = true } = {}) {
  // Layout inside TIFF (starts at offset 0 of tiffBuf):
  //   0..7:   TIFF header (II/MM, 42, offset 8)
  //   8..33:  IFD0 (2 entries: Orientation=6, ExifIFDPointer=38) + nextIFD(0)
  //   38..115: ExifIFD (6 entries: ExposureTime, FNumber, ISO, DateTimeOriginal, OffsetTimeOriginal, Focal35mm) + nextIFD(0)
  //   120..127: ExposureTime rational (1 / 250)
  //   128..135: FNumber rational (28 / 10 -> f/2.8)
  //   136..155: DateTimeOriginal "2026:07:19 17:42:10\0"
  //   156..162: OffsetTimeOriginal "-07:00\0"
  const tiff = new ArrayBuffer(176)
  const v = new DataView(tiff)
  const u8 = new Uint8Array(tiff)
  v.setUint16(0, littleEndian ? 0x4949 : 0x4d4d, false)
  v.setUint16(2, 0x002a, littleEndian)
  v.setUint32(4, 8, littleEndian)

  const writeEntry = (pos, tag, type, count, valOrOffset, inlineShort = false) => {
    v.setUint16(pos, tag, littleEndian)
    v.setUint16(pos + 2, type, littleEndian)
    v.setUint32(pos + 4, count, littleEndian)
    if (inlineShort) v.setUint16(pos + 8, valOrOffset, littleEndian)
    else v.setUint32(pos + 8, valOrOffset, littleEndian)
  }

  // IFD0 at 8
  v.setUint16(8, 2, littleEndian)
  writeEntry(10, 0x0112, 3, 1, 6, true)     // Orientation = 6
  writeEntry(22, 0x8769, 4, 1, 38, false)   // ExifIFD pointer = 38
  v.setUint32(34, 0, littleEndian)

  // ExifIFD at 38
  v.setUint16(38, 6, littleEndian)
  writeEntry(40, 0x829a, 5, 1, 120)         // ExposureTime @ 120
  writeEntry(52, 0x829d, 5, 1, 128)         // FNumber @ 128
  writeEntry(64, 0x8827, 3, 1, 400, true)   // ISO = 400
  writeEntry(76, 0x9003, 2, 20, 136)        // DateTimeOriginal @ 136
  writeEntry(88, 0x9010, 2, 7, 156)         // OffsetTimeOriginal @ 156
  writeEntry(100, 0xa405, 3, 1, 35, true)   // FocalLenIn35mmFilm = 35
  v.setUint32(112, 0, littleEndian)

  // Rationals & ASCII
  v.setUint32(120, 1, littleEndian)
  v.setUint32(124, 250, littleEndian)
  v.setUint32(128, 28, littleEndian)
  v.setUint32(132, 10, littleEndian)
  const writeStr = (offset, s) => {
    for (let i = 0; i < s.length; i++) u8[offset + i] = s.charCodeAt(i)
  }
  writeStr(136, '2026:07:19 17:42:10\0')
  writeStr(156, '-07:00\0')

  // Wrap in SOI + APP1 ("Exif\0\0" + tiff) + EOI
  const segLen = 2 + 6 + u8.byteLength
  const jpeg = new Uint8Array(2 + 2 + segLen + 2)
  jpeg[0] = 0xff; jpeg[1] = 0xd8
  jpeg[2] = 0xff; jpeg[3] = 0xe1
  jpeg[4] = (segLen >> 8) & 0xff; jpeg[5] = segLen & 0xff
  const exifHdr = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
  jpeg.set(exifHdr, 6)
  jpeg.set(u8, 12)
  jpeg[jpeg.length - 2] = 0xff; jpeg[jpeg.length - 1] = 0xd9
  return jpeg
}

describe('full-frame web upload sizing and image detection', () => {
  it('scales s, m and l copies along the long edge without cropping', () => {
    expect(tierDimensions(4032, 3024, 's')).toEqual({ width: 320, height: 240 })
    expect(tierDimensions(4032, 3024, 'm')).toEqual({ width: 800, height: 600 })
    expect(tierDimensions(4032, 3024, 'l')).toEqual({ width: 1800, height: 1350 })
    // Portrait keeps exact 2:3 shape
    expect(tierDimensions(2000, 3000, 'l')).toEqual({ width: 1200, height: 1800 })
  })

  it('gives panoramas wider than 2.2:1 1.6x the long edge, matching ShareCopyMaker', () => {
    // 6000 x 2000 is 3:1 (> 2.2), so l gets 1800 * 1.6 = 2880 on the long edge -> 2880 x 960
    expect(tierDimensions(6000, 2000, 'l')).toEqual({ width: 2880, height: 960 })
    expect(tierDimensions(6000, 2000, 's')).toEqual({ width: 512, height: 171 })
  })

  it('never upscales images smaller than a tier', () => {
    expect(tierDimensions(640, 480, 'l')).toEqual({ width: 640, height: 480 })
    expect(tierDimensions(640, 480, 'm')).toEqual({ width: 640, height: 480 })
    expect(tierDimensions(640, 480, 's')).toEqual({ width: 320, height: 240 })
  })

  it('detects JPEG, PNG, WebP and HEIC magic bytes at .heic storage paths', () => {
    expect(detectImageMime(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))).toBe('image/jpeg')
    expect(detectImageMime(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))).toBe('image/png')
    expect(detectImageMime(new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]))).toBe('image/webp')
    expect(detectImageMime(new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]))).toBe('image/heic')
    expect(detectImageMime(new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66]))).toBe('image/avif')
  })

  it('accepts HEIC files even when the browser leaves file.type blank', () => {
    expect(isSupportedImageFile({ name: 'IMG_4021.HEIC', type: '' })).toBe(true)
    expect(isSupportedImageFile({ name: 'scan.jpg', type: 'image/jpeg' })).toBe(true)
    expect(isSupportedImageFile({ name: 'notes.pdf', type: 'application/pdf' })).toBe(false)
  })

  it('maps custom and preset batch walls to legacy iOS walls', () => {
    expect(legacyWallFor('dark')).toBe('dark')
    expect(legacyWallFor('desk')).toBe('desk')
    expect(legacyWallFor('kraft')).toBe('light')
    expect(legacyWallFor('#101214')).toBe('dark')
    expect(legacyWallFor('#f5efe2')).toBe('light')
  })
})

describe('EXIF extraction before canvas strips metadata', () => {
  it('parses little-endian and big-endian JPEG EXIF tags accurately', () => {
    for (const littleEndian of [true, false]) {
      const parsed = parseExif(makeExifJpeg({ littleEndian }))
      expect(parsed).toEqual({
        orientation: 6,
        capturedAt: '2026-07-20T00:42:10.000Z',
        exif: {
          aperture: 2.8,
          shutter: '1/250',
          iso: 400,
          focalLength: 35,
        },
      })
    }
  })

  it('formats shutter speeds and EXIF dates cleanly', () => {
    expect(formatShutter(0.004)).toBe('1/250')
    expect(formatShutter(2)).toBe('2s')
    expect(formatShutter(1.5)).toBe('1.5s')
    expect(parseDurationSeconds('0.0025s')).toBe(0.0025)
    expect(parseExifDate('2026:11:17 09:15:00', '+00:00')).toBe('2026-11-17T09:15:00.000Z')
  })

  it('falls back to Google Photos metadata when downloaded JPEG has no camera EXIF', () => {
    const merged = mergePhotoMeta(
      { orientation: 1, capturedAt: null, exif: null },
      { capturedAt: '2026-08-01T12:00:00.000Z', exif: { aperture: 1.8, shutter: '1/500', iso: 64 } },
    )
    expect(merged).toEqual({
      capturedAt: '2026-08-01T12:00:00.000Z',
      exif: { aperture: 1.8, shutter: '1/500', iso: 64 },
    })
  })
})

describe('Google Photos Picker API integration', () => {
  it('appends /autoclose once to pickerUri and parses polling intervals', () => {
    expect(normalizePickerUri('https://photos.google.com/photospicker/abc123')).toBe('https://photos.google.com/photospicker/abc123/autoclose')
    expect(normalizePickerUri('https://photos.google.com/photospicker/abc123/autoclose')).toBe('https://photos.google.com/photospicker/abc123/autoclose')
    expect(parsePollIntervalMs('3s')).toBe(3000)
    expect(parsePollIntervalMs('0.2s')).toBe(1500)
    expect(fullFrameDownloadUrl('https://lh3.googleusercontent.com/pw/xyz')).toBe('https://lh3.googleusercontent.com/pw/xyz=w4096-h4096')
  })

  it('extracts capture time and camera EXIF from PickedMediaItem metadata', () => {
    const meta = extractGoogleMediaMeta({
      id: 'm1',
      createTime: '2026-09-12T16:30:00Z',
      type: 'PHOTO',
      mediaFile: {
        baseUrl: 'https://lh3.googleusercontent.com/pw/item1',
        mimeType: 'image/jpeg',
        filename: 'DSCF0102.JPG',
        mediaFileMetadata: {
          width: 6240,
          height: 4160,
          photoMetadata: {
            apertureFNumber: 2,
            exposureTime: '0.001s',
            isoEquivalent: 160,
            focalLength: 23.4,
          },
        },
      },
    })
    expect(meta).toEqual({
      capturedAt: '2026-09-12T16:30:00.000Z',
      exif: { aperture: 2, shutter: '1/1000', iso: 160, focalLength: 23 },
      sourceKind: 'google-photos',
    })
  })

  it('creates sessions, follows pagination on mediaItems, and downloads full-frame bytes with Bearer auth', async () => {
    const mockFetch = vi.fn(async (url, opts) => {
      if (url.endsWith('/sessions') && opts?.method === 'POST') {
        expect(opts.headers.Authorization).toBe('Bearer tok_123')
        expect(JSON.parse(opts.body)).toEqual({ pickingConfig: { maxItemCount: '25' } })
        return new Response(JSON.stringify({ id: 'sess_1', pickerUri: 'https://photos.google.com/photospicker/sess_1' }), { status: 200 })
      }
      if (url.includes('/mediaItems?') && !url.includes('pageToken=p2')) {
        return new Response(JSON.stringify({ mediaItems: [{ id: 'a' }], nextPageToken: 'p2' }), { status: 200 })
      }
      if (url.includes('pageToken=p2')) {
        return new Response(JSON.stringify({ mediaItems: [{ id: 'b' }] }), { status: 200 })
      }
      if (url === 'https://lh3.googleusercontent.com/pw/photo1=w4096-h4096') {
        expect(opts.headers.Authorization).toBe('Bearer tok_123')
        return new Response(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), {
          status: 200,
          headers: { 'Content-Type': 'image/jpeg' },
        })
      }
      return new Response('not found', { status: 404 })
    })

    const session = await createPickerSession('tok_123', { maxItemCount: 25 }, mockFetch)
    expect(session.id).toBe('sess_1')

    const items = await listPickedMediaItems('tok_123', 'sess_1', mockFetch)
    expect(items.map((x) => x.id)).toEqual(['a', 'b'])

    const file = await downloadGoogleMediaFile('tok_123', {
      id: 'p1',
      mediaFile: {
        baseUrl: 'https://lh3.googleusercontent.com/pw/photo1',
        filename: 'coast.jpg',
        mimeType: 'image/jpeg',
      },
    }, mockFetch)
    expect(file.name).toBe('coast.jpg')
    expect(file.type).toBe('image/jpeg')
    expect(file.size).toBe(4)
  })
})

// End-to-end tests for the Google Photos Picker flow (pickFromGooglePhotos) with Google Identity
// Services, window.open, fetch and the local image pipeline all stubbed. Each test loads a fresh
// copy of the module so the in-memory token cache starts empty.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./upload.js', () => ({
  preparePhotoFile: vi.fn(async (file, meta) => ({ name: file.name, type: file.type, size: file.size, ...meta })),
}))

const API = 'https://photospicker.googleapis.com/v1'
const jpegBytes = () => new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0xff, 0xd9])

function photo(id, extra = {}) {
  return {
    id,
    createTime: '2026-09-12T16:30:00.123Z',
    type: 'PHOTO',
    mediaFile: { baseUrl: `https://lh3.googleusercontent.com/pw/${id}`, mimeType: 'image/jpeg', filename: `${id}.jpg` },
    ...extra,
  }
}

/** A fake Google: token client, picker window and REST API, with knobs per test. */
function fakeGoogle({
  items = [photo('a'), photo('b')],
  tokenResponse = { access_token: 'tok_1', expires_in: 3599 },
  tokenError = null,
  readyAfterPolls = 1,
  sessionExtra = {},
  popupBlocked = false,
  closePopupAfterPolls = null,
  download = null,
} = {}) {
  const calls = { token: 0, polls: 0, deletes: 0, opens: 0, fetches: [] }
  const popup = { closed: false, close: vi.fn(() => { popup.closed = true }) }

  globalThis.window = {
    google: {
      accounts: {
        oauth2: {
          initTokenClient: ({ callback, error_callback }) => ({
            requestAccessToken: () => {
              calls.token += 1
              queueMicrotask(() => (tokenError ? error_callback(tokenError) : callback(tokenResponse)))
            },
          }),
        },
      },
    },
    open: vi.fn(() => {
      calls.opens += 1
      return popupBlocked && calls.opens === 1 ? null : popup
    }),
    __BATCHES_GOOGLE_CLIENT_ID__: '123-abc.apps.googleusercontent.com',
  }

  globalThis.fetch = vi.fn(async (url, opts = {}) => {
    calls.fetches.push({ url, method: opts.method || 'GET', auth: opts.headers?.Authorization })
    if (url === `${API}/sessions` && opts.method === 'POST') {
      return Response.json({
        id: 'sess_1',
        pickerUri: 'https://photos.google.com/photospicker/sess_1',
        pollingConfig: { pollInterval: '2s', timeoutIn: '1800s' },
        mediaItemsSet: false,
        ...sessionExtra,
      })
    }
    if (url === `${API}/sessions/sess_1` && opts.method === 'DELETE') {
      calls.deletes += 1
      return Response.json({})
    }
    if (url === `${API}/sessions/sess_1`) {
      calls.polls += 1
      if (closePopupAfterPolls !== null && calls.polls >= closePopupAfterPolls) popup.closed = true
      return Response.json({ id: 'sess_1', mediaItemsSet: calls.polls >= readyAfterPolls })
    }
    if (url.startsWith(`${API}/mediaItems?`)) {
      return Response.json({ mediaItems: items })
    }
    if (url.startsWith('https://lh3.googleusercontent.com/')) {
      if (download) return download(url)
      return new Response(jpegBytes(), { status: 200, headers: { 'Content-Type': 'image/jpeg' } })
    }
    return new Response('{}', { status: 404 })
  })

  return { calls, popup }
}

/** Runs a promise to completion while fake timers drive its polling sleeps. */
async function settle(promise) {
  let outcome
  promise.then((value) => { outcome = { value } }, (error) => { outcome = { error } })
  for (let i = 0; i < 2000 && !outcome; i++) await vi.advanceTimersByTimeAsync(250)
  if (!outcome) throw new Error('flow never settled')
  if (outcome.error) throw outcome.error
  return outcome.value
}

let gp
beforeEach(async () => {
  vi.useFakeTimers()
  vi.resetModules()
  gp = await import('./googlePhotos.js')
})
afterEach(() => {
  vi.useRealTimers()
  delete globalThis.window
})

describe('pickFromGooglePhotos', () => {
  it('signs in, opens the autoclose picker, polls until done, downloads full frame, and cleans up', async () => {
    const { calls, popup } = fakeGoogle({ readyAfterPolls: 2 })
    const stages = []
    const result = await settle(gp.pickFromGooglePhotos({ maxCount: 60, onStatus: (s) => stages.push(s.stage) }))

    expect(result.skippedVideos).toBe(0)
    expect(result.photos.map((p) => p.name)).toEqual(['a.jpg', 'b.jpg'])
    expect(result.photos[0]).toMatchObject({ type: 'image/jpeg', sourceKind: 'google-photos', capturedAt: '2026-09-12T16:30:00.123Z' })
    expect(window.open).toHaveBeenCalledWith('https://photos.google.com/photospicker/sess_1/autoclose', 'batches-google-photos', expect.any(String))
    expect(calls.polls).toBe(2)
    expect(stages).toEqual(['authorizing', 'creating-session', 'picking', 'listing', 'downloading', 'downloading', 'downloading'])

    const downloads = calls.fetches.filter((f) => f.url.startsWith('https://lh3'))
    expect(downloads.map((f) => f.url)).toEqual([
      'https://lh3.googleusercontent.com/pw/a=w4096-h4096',
      'https://lh3.googleusercontent.com/pw/b=w4096-h4096',
    ])
    // Every Google call carries the token.
    expect(calls.fetches.every((f) => f.auth === 'Bearer tok_1')).toBe(true)
    expect(calls.deletes).toBe(1)
    // The window was still open (the fake doesn't autoclose), so cleanup closes it.
    expect(popup.close).toHaveBeenCalledTimes(1)
  })

  it('skips videos, caps at maxCount and reports how many were left out', async () => {
    fakeGoogle({
      items: [
        photo('a'),
        photo('v1', { type: 'VIDEO', mediaFile: { baseUrl: 'https://lh3.googleusercontent.com/pw/v1', mimeType: 'video/mp4' } }),
        photo('b'),
        photo('c', { type: undefined, mediaFile: { baseUrl: 'https://lh3.googleusercontent.com/pw/c', mimeType: 'video/quicktime' } }),
        photo('d'),
      ],
    })
    const result = await settle(gp.pickFromGooglePhotos({ maxCount: 2 }))
    expect(result.photos.map((p) => p.name)).toEqual(['a.jpg', 'b.jpg'])
    // Two videos plus one photo over the cap: the count describes everything not imported.
    expect(result.skippedVideos).toBe(3)
  })

  it('reuses the cached token for a second pick and asks again after a 401', async () => {
    const { calls } = fakeGoogle()
    await settle(gp.pickFromGooglePhotos())
    await settle(gp.pickFromGooglePhotos())
    expect(calls.token).toBe(1)

    // Next session create comes back 401: the token is dropped and the following pick re-auths.
    const realFetch = globalThis.fetch
    globalThis.fetch = vi.fn(async (url, opts) => (url === `${API}/sessions` ? new Response('', { status: 401 }) : realFetch(url, opts)))
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toThrow(/session expired/)
    globalThis.fetch = realFetch
    await settle(gp.pickFromGooglePhotos())
    expect(calls.token).toBe(2)
  })

  it('clearGooglePhotosSession forgets the token', async () => {
    const { calls } = fakeGoogle()
    await settle(gp.pickFromGooglePhotos())
    gp.clearGooglePhotosSession()
    await settle(gp.pickFromGooglePhotos())
    expect(calls.token).toBe(2)
  })

  it('treats the picker window closing without a selection as a cancel, after two checks', async () => {
    const { calls } = fakeGoogle({ readyAfterPolls: Infinity, closePopupAfterPolls: 1 })
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toBeInstanceOf(gp.GooglePhotosCancelledError)
    // 1 poll that saw it open then closed, then two closed checks.
    expect(calls.polls).toBe(3)
    expect(calls.deletes).toBe(1)
  })

  it('does not cancel when autoclose shuts the window just as the selection lands', async () => {
    // Window closes at poll 1; mediaItemsSet becomes true on the first closed check (poll 2).
    const { calls } = fakeGoogle({ readyAfterPolls: 2, closePopupAfterPolls: 1 })
    const result = await settle(gp.pickFromGooglePhotos())
    expect(result.photos).toHaveLength(2)
    expect(calls.polls).toBe(2)
  })

  it('exposes reopen when the popup is blocked and keeps polling', async () => {
    const { calls } = fakeGoogle({ popupBlocked: true, readyAfterPolls: 2 })
    let picking
    const run = gp.pickFromGooglePhotos({ onStatus: (s) => { if (s.stage === 'picking') picking = s } })
    const result = await settle(run)
    expect(picking.popupBlocked).toBe(true)
    expect(typeof picking.reopen).toBe('function')
    expect(picking.reopen()).not.toBeNull()
    expect(calls.opens).toBe(2)
    expect(result.photos).toHaveLength(2)
  })

  it('stops on abort while waiting and still deletes the session and closes the window', async () => {
    const { calls, popup } = fakeGoogle({ readyAfterPolls: Infinity })
    const controller = new AbortController()
    const run = gp.pickFromGooglePhotos({ signal: controller.signal })
    await vi.advanceTimersByTimeAsync(2500)
    controller.abort()
    await expect(settle(run)).rejects.toBeInstanceOf(gp.GooglePhotosCancelledError)
    expect(calls.deletes).toBe(1)
    expect(popup.close).toHaveBeenCalled()
  })

  it('times out at the session timeoutIn (clamped to at least 30s)', async () => {
    const { calls } = fakeGoogle({ readyAfterPolls: Infinity, sessionExtra: { pollingConfig: { pollInterval: '5s', timeoutIn: '10s' } } })
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toThrow(/timed out/)
    expect(calls.polls).toBeGreaterThanOrEqual(6)
    expect(calls.polls).toBeLessThanOrEqual(8)
    expect(calls.deletes).toBe(1)
  })

  it('skips polling when the new session is already set', async () => {
    const { calls } = fakeGoogle({ sessionExtra: { mediaItemsSet: true } })
    await settle(gp.pickFromGooglePhotos())
    expect(calls.polls).toBe(0)
  })

  it('maps a denied consent to a cancel and a blocked sign-in popup to a clear message', async () => {
    fakeGoogle({ tokenResponse: { error: 'access_denied' } })
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toBeInstanceOf(gp.GooglePhotosCancelledError)

    vi.resetModules()
    gp = await import('./googlePhotos.js')
    fakeGoogle({ tokenError: { type: 'popup_failed_to_open' } })
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toThrow(/blocked the Google sign-in popup/)

    vi.resetModules()
    gp = await import('./googlePhotos.js')
    fakeGoogle({ tokenError: { type: 'popup_closed' } })
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toBeInstanceOf(gp.GooglePhotosCancelledError)
  })

  it('refuses to start without a client ID', async () => {
    // web/.env.local may set a real ID; blank it for this test.
    vi.stubEnv('VITE_GOOGLE_CLIENT_ID', '')
    fakeGoogle()
    window.__BATCHES_GOOGLE_CLIENT_ID__ = 'placeholder'
    try {
      expect(gp.isGooglePhotosConfigured()).toBe(false)
      await expect(gp.pickFromGooglePhotos()).rejects.toBeInstanceOf(gp.GooglePhotosConfigError)
      expect(fetch).not.toHaveBeenCalled()
    } finally {
      vi.unstubAllEnvs()
    }
  })

  it('fails on a session reply with no picker link and still does not leak a popup', async () => {
    fakeGoogle({ sessionExtra: { pickerUri: '' } })
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toThrow(/valid picker session/)
    expect(window.open).not.toHaveBeenCalled()
  })

  it('surfaces Google API error messages', async () => {
    fakeGoogle()
    const realFetch = globalThis.fetch
    globalThis.fetch = vi.fn(async (url, opts) => (url === `${API}/sessions`
      ? Response.json({ error: { message: 'Quota exceeded' } }, { status: 429 })
      : realFetch(url, opts)))
    await expect(settle(gp.pickFromGooglePhotos())).rejects.toThrow('Quota exceeded')
  })
})

describe('downloadGoogleMediaFile', () => {
  it('falls back to =d when the sized copy fails, and names the photo when both fail', async () => {
    const seen = []
    const fetchImpl = vi.fn(async (url) => {
      seen.push(url)
      return url.endsWith('=d')
        ? new Response(jpegBytes(), { status: 200, headers: { 'Content-Type': 'image/jpeg' } })
        : new Response('', { status: 403 })
    })
    const file = await gp.downloadGoogleMediaFile('t', photo('x'), fetchImpl)
    expect(seen).toEqual(['https://lh3.googleusercontent.com/pw/x=w4096-h4096', 'https://lh3.googleusercontent.com/pw/x=d'])
    expect(file.size).toBe(8)

    const failing = vi.fn(async () => new Response('', { status: 500 }))
    await expect(gp.downloadGoogleMediaFile('t', photo('IMG_9.HEIC'), failing)).rejects.toThrow('IMG_9.HEIC.jpg')
  })

  it('sends no cookies and uses the item mime type when the reply has none', async () => {
    let opts
    const fetchImpl = vi.fn(async (_url, o) => { opts = o; return new Response(new Blob([jpegBytes()]), { status: 200 }) })
    const item = photo('y', { mediaFile: { baseUrl: 'https://lh3.googleusercontent.com/pw/y', mimeType: 'image/heic', filename: 'y.heic' } })
    const file = await gp.downloadGoogleMediaFile('t', item, fetchImpl)
    expect(opts.credentials).toBe('omit')
    expect(file.type).toBe('image/heic') // magic-byte sniffing in upload.js corrects this to JPEG later
  })

  it('rejects an item with no baseUrl', async () => {
    await expect(gp.downloadGoogleMediaFile('t', { id: 'z', mediaFile: {} }, vi.fn())).rejects.toThrow(/download link/)
  })
})

describe('Picker REST helpers', () => {
  it('clamps maxItemCount to 1...60', async () => {
    const bodies = []
    const fetchImpl = vi.fn(async (_u, o) => { bodies.push(JSON.parse(o.body)); return Response.json({ id: 's' }) })
    await gp.createPickerSession('t', { maxItemCount: 0 }, fetchImpl)
    await gp.createPickerSession('t', { maxItemCount: 500 }, fetchImpl)
    await gp.createPickerSession('t', { maxItemCount: 12.6 }, fetchImpl)
    expect(bodies.map((b) => b.pickingConfig.maxItemCount)).toEqual(['1', '60', '13'])
  })

  it('stops paging after 10 pages even if Google keeps sending tokens', async () => {
    let n = 0
    const fetchImpl = vi.fn(async () => { n += 1; return Response.json({ mediaItems: [{ id: String(n) }], nextPageToken: `p${n}` }) })
    const items = await gp.listPickedMediaItems('t', 's', fetchImpl)
    expect(items).toHaveLength(10)
    expect(fetchImpl).toHaveBeenCalledTimes(10)
  })

  it('handles an empty selection page', async () => {
    const items = await gp.listPickedMediaItems('t', 's', vi.fn(async () => Response.json({})))
    expect(items).toEqual([])
  })

  it('swallows DELETE failures', async () => {
    await expect(gp.deletePickerSession('t', 's', vi.fn(async () => { throw new Error('offline') }))).resolves.toBeNull()
  })

  it('url-encodes the session id', async () => {
    const fetchImpl = vi.fn(async () => Response.json({}))
    await gp.getPickerSession('t', 'a/b?c', fetchImpl)
    expect(fetchImpl.mock.calls[0][0]).toBe(`${API}/sessions/a%2Fb%3Fc`)
  })

  it('parses durations defensively', () => {
    expect(gp.parsePollIntervalMs(undefined)).toBe(3000)
    expect(gp.parsePollIntervalMs('60s')).toBe(10000)
    expect(gp.parsePollIntervalMs('bogus')).toBe(3000)
    expect(gp.parseTimeoutMs('5s')).toBe(30000)
    expect(gp.parseTimeoutMs('99999s')).toBe(3600000)
    expect(gp.parseTimeoutMs(null)).toBe(1200000)
    expect(gp.normalizePickerUri('https://photos.google.com/photospicker/x/')).toBe('https://photos.google.com/photospicker/x/autoclose')
    expect(gp.normalizePickerUri('')).toBe('')
  })
})

describe('extractGoogleMediaMeta', () => {
  it('accepts numeric fields sent as strings, as the iOS decoder does', () => {
    const meta = gp.extractGoogleMediaMeta(photo('s', {
      mediaFile: {
        baseUrl: 'x',
        mediaFileMetadata: { width: '4032', height: '3024', photoMetadata: { apertureFNumber: '1.78', isoEquivalent: '50', focalLength: '6.86', exposureTime: '0.0083s' } },
      },
    }))
    expect(meta.exif).toEqual({ aperture: 1.78, shutter: '1/120', iso: 50, focalLength: 7 })
  })

  it('returns null exif and date for missing or junk metadata', () => {
    expect(gp.extractGoogleMediaMeta({ createTime: 'not a date', mediaFile: { mediaFileMetadata: { photoMetadata: { apertureFNumber: 0, isoEquivalent: -1, exposureTime: '0s' } } } }))
      .toEqual({ capturedAt: null, exif: null, sourceKind: 'google-photos' })
    expect(gp.extractGoogleMediaMeta(undefined)).toEqual({ capturedAt: null, exif: null, sourceKind: 'google-photos' })
  })
})

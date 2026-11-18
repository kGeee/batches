// Google Photos integration using the Google Photos Picker API (photospicker.googleapis.com/v1).
//
// Why Picker API rather than the retired Library API:
//   - Only the photos the person chooses in Google's own picker are shared with this browser tab;
//     Batches never asks for read access to their whole Google Photos library.
//   - Google Identity Services (`accounts.google.com/gsi/client`) is loaded only when someone
//     clicks "Google Photos", so normal visits make zero requests to Google.
//   - Each picked photo is downloaded full frame (`=w4096-h4096`, no crop), run through the same
//     local s/m/l canvas ladder as device uploads, and never passes through a third-party server.
import { formatShutter, parseDurationSeconds } from './exif.js'
import { preparePhotoFile } from './upload.js'

const PICKER_API = 'https://photospicker.googleapis.com/v1'
const PICKER_SCOPE = 'https://www.googleapis.com/auth/photospicker.mediaitems.readonly'
const GSI_SRC = 'https://accounts.google.com/gsi/client'

export class GooglePhotosConfigError extends Error {
  constructor(message) {
    super(message)
    this.name = 'GooglePhotosConfigError'
  }
}

export class GooglePhotosCancelledError extends Error {
  constructor() {
    super('Google Photos selection was cancelled.')
    this.name = 'GooglePhotosCancelledError'
  }
}

export function googleClientID() {
  const fromEnv = import.meta.env?.VITE_GOOGLE_CLIENT_ID
  const fromMeta = typeof document !== 'undefined'
    ? document.querySelector('meta[name="batches-google-client-id"]')?.getAttribute('content')
    : ''
  const fromGlobal = typeof window !== 'undefined' ? window.__BATCHES_GOOGLE_CLIENT_ID__ : ''
  const raw = [fromEnv, fromMeta, fromGlobal].find((v) => typeof v === 'string' && v.trim() && !v.includes('placeholder'))
  return raw ? raw.trim() : ''
}

export function isGooglePhotosConfigured() {
  return Boolean(googleClientID())
}

// OAuth token in memory only; cleared on sign-out.
let cachedToken = null   // { accessToken, expiresAt }
let gsiPromise = null

export function clearGooglePhotosSession() {
  cachedToken = null
}

function loadGoogleIdentityScript() {
  if (typeof window !== 'undefined' && window.google?.accounts?.oauth2) {
    return Promise.resolve(window.google.accounts.oauth2)
  }
  gsiPromise ??= new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${GSI_SRC}"]`)
    const script = existing ?? document.createElement('script')
    script.async = true
    script.defer = true
    const onLoad = () => {
      if (window.google?.accounts?.oauth2) resolve(window.google.accounts.oauth2)
      else { gsiPromise = null; reject(new Error('Google sign-in script loaded without OAuth support.')) }
    }
    const onError = () => {
      gsiPromise = null
      if (!existing) script.remove()
      reject(new Error("Couldn't reach Google sign-in. Check your connection or content blockers."))
    }
    script.addEventListener('load', onLoad, { once: true })
    script.addEventListener('error', onError, { once: true })
    if (!existing) {
      script.src = GSI_SRC
      document.head.appendChild(script)
    }
  })
  return gsiPromise
}

export async function requestGooglePhotosToken({ forcePrompt = false } = {}) {
  const clientId = googleClientID()
  if (!clientId) {
    throw new GooglePhotosConfigError(
      'Google Photos needs VITE_GOOGLE_CLIENT_ID configured for this deployment.',
    )
  }
  if (!forcePrompt && cachedToken && cachedToken.expiresAt > Date.now()) {
    return cachedToken.accessToken
  }
  const oauth2 = await loadGoogleIdentityScript()
  return new Promise((resolve, reject) => {
    let settled = false
    const client = oauth2.initTokenClient({
      client_id: clientId,
      scope: PICKER_SCOPE,
      callback: (resp) => {
        if (settled) return
        settled = true
        if (resp?.error || !resp?.access_token) {
          if (resp?.error === 'access_denied') {
            reject(new GooglePhotosCancelledError())
          } else {
            reject(new Error(resp?.error_description || resp?.error || 'Google authorization did not complete.'))
          }
          return
        }
        const ttlSec = Math.max(60, Number(resp.expires_in) || 3600)
        cachedToken = {
          accessToken: resp.access_token,
          expiresAt: Date.now() + (ttlSec - 60) * 1000,
        }
        resolve(resp.access_token)
      },
      error_callback: (err) => {
        if (settled) return
        settled = true
        if (err?.type === 'popup_closed') {
          reject(new GooglePhotosCancelledError())
        } else if (err?.type === 'popup_failed_to_open') {
          reject(new Error('Your browser blocked the Google sign-in popup. Allow popups for this site and try again.'))
        } else {
          reject(new Error(err?.message || 'Google sign-in could not open.'))
        }
      },
    })
    client.requestAccessToken({ prompt: forcePrompt ? 'consent' : '' })
  })
}

// Pure helpers (exported for tests) --------------------------------------------------------------

export function normalizePickerUri(pickerUri) {
  if (typeof pickerUri !== 'string' || !pickerUri.trim()) return ''
  const clean = pickerUri.trim().replace(/\/+$/, '')
  return clean.endsWith('/autoclose') ? clean : `${clean}/autoclose`
}

export function parsePollIntervalMs(raw, fallbackMs = 3000) {
  const sec = parseDurationSeconds(raw)
  if (sec !== null) return Math.min(10000, Math.max(1500, Math.round(sec * 1000)))
  return fallbackMs
}

export function parseTimeoutMs(raw, fallbackMs = 20 * 60 * 1000) {
  const sec = parseDurationSeconds(raw)
  if (sec !== null) return Math.min(60 * 60 * 1000, Math.max(30000, Math.round(sec * 1000)))
  return fallbackMs
}

/** Maps a PickedMediaItem's metadata to Batches' { capturedAt, exif } shape. */
export function extractGoogleMediaMeta(item) {
  let capturedAt = null
  if (typeof item?.createTime === 'string') {
    const d = new Date(item.createTime)
    if (!Number.isNaN(d.getTime())) capturedAt = d.toISOString()
  }
  const pm = item?.mediaFile?.mediaFileMetadata?.photoMetadata
  const exif = {}
  if (typeof pm?.apertureFNumber === 'number' && pm.apertureFNumber > 0) {
    exif.aperture = Math.round(pm.apertureFNumber * 100) / 100
  }
  const exposureSec = parseDurationSeconds(pm?.exposureTime)
  const shutter = exposureSec !== null ? formatShutter(exposureSec) : null
  if (shutter) exif.shutter = shutter
  if (typeof pm?.isoEquivalent === 'number' && pm.isoEquivalent > 0) {
    exif.iso = Math.round(pm.isoEquivalent)
  }
  if (typeof pm?.focalLength === 'number' && pm.focalLength > 0) {
    exif.focalLength = Math.round(pm.focalLength)
  }
  return {
    capturedAt,
    exif: Object.keys(exif).length ? exif : null,
    sourceKind: 'google-photos',
  }
}

export function fullFrameDownloadUrl(baseUrl) {
  if (typeof baseUrl !== 'string' || !baseUrl) return ''
  // =w4096-h4096 fits inside 4096x4096 without cropping (-c is omitted) and returns oriented JPEG.
  return `${baseUrl}=w4096-h4096`
}

// Picker REST calls ------------------------------------------------------------------------------

async function pickerFetch(url, accessToken, options = {}, fetchImpl = fetch) {
  const res = await fetchImpl(url, {
    ...options,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      ...(options.headers || {}),
    },
  })
  if (res.status === 401) {
    cachedToken = null
    throw new Error('Your Google Photos session expired. Click Google Photos to reconnect.')
  }
  if (!res.ok) {
    let detail = ''
    try {
      const body = await res.json()
      detail = body?.error?.message || ''
    } catch { /* ignore */ }
    throw new Error(detail || `Google Photos returned HTTP ${res.status}.`)
  }
  if (res.status === 204) return null
  const text = await res.text()
  return text ? JSON.parse(text) : null
}

export async function createPickerSession(accessToken, { maxItemCount = 60 } = {}, fetchImpl = fetch) {
  const count = Math.max(1, Math.min(60, Math.round(maxItemCount)))
  return pickerFetch(
    `${PICKER_API}/sessions`,
    accessToken,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pickingConfig: { maxItemCount: String(count) } }),
    },
    fetchImpl,
  )
}

export async function getPickerSession(accessToken, sessionId, fetchImpl = fetch) {
  return pickerFetch(`${PICKER_API}/sessions/${encodeURIComponent(sessionId)}`, accessToken, {}, fetchImpl)
}

export async function deletePickerSession(accessToken, sessionId, fetchImpl = fetch) {
  return pickerFetch(
    `${PICKER_API}/sessions/${encodeURIComponent(sessionId)}`,
    accessToken,
    { method: 'DELETE' },
    fetchImpl,
  ).catch(() => null)
}

export async function listPickedMediaItems(accessToken, sessionId, fetchImpl = fetch) {
  const items = []
  let pageToken = ''
  for (let page = 0; page < 10; page++) {
    const qs = new URLSearchParams({ sessionId, pageSize: '100' })
    if (pageToken) qs.set('pageToken', pageToken)
    const data = await pickerFetch(`${PICKER_API}/mediaItems?${qs}`, accessToken, {}, fetchImpl)
    if (Array.isArray(data?.mediaItems)) items.push(...data.mediaItems)
    if (!data?.nextPageToken) break
    pageToken = data.nextPageToken
  }
  return items
}

export async function downloadGoogleMediaFile(accessToken, item, fetchImpl = fetch) {
  const baseUrl = item?.mediaFile?.baseUrl
  if (!baseUrl) throw new Error('Google Photos did not return a download link for a selected photo.')
  const headers = { Authorization: `Bearer ${accessToken}` }
  let res = await fetchImpl(fullFrameDownloadUrl(baseUrl), { headers, credentials: 'omit' })
  if (!res.ok) {
    res = await fetchImpl(`${baseUrl}=d`, { headers, credentials: 'omit' })
  }
  if (!res.ok) {
    throw new Error(`Couldn't download “${item.mediaFile?.filename || 'photo'}” from Google Photos.`)
  }
  const blob = await res.blob()
  const rawName = item.mediaFile?.filename || `google-photo-${item.id || 'item'}.jpg`
  const type = blob.type || item.mediaFile?.mimeType || 'image/jpeg'
  return new File([blob], rawName, { type })
}

function waitMs(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(new GooglePhotosCancelledError()); return }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    const onAbort = () => {
      clearTimeout(timer)
      reject(new GooglePhotosCancelledError())
    }
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

/**
 * End-to-end Google Photos Picker flow:
 *   1. Authorizes with Google Identity Services (photospicker.mediaitems.readonly)
 *   2. Creates a Picker session capped to `maxCount`
 *   3. Opens Google's picker window (and exposes `reopen` if a browser popup blocker intervened)
 *   4. Polls until selection finishes, downloads the chosen photos full frame, and prepares them.
 */
export async function pickFromGooglePhotos({ maxCount = 60, onStatus, signal } = {}) {
  if (signal?.aborted) throw new GooglePhotosCancelledError()
  onStatus?.({ stage: 'authorizing' })
  const accessToken = await requestGooglePhotosToken()
  if (signal?.aborted) throw new GooglePhotosCancelledError()

  onStatus?.({ stage: 'creating-session' })
  const session = await createPickerSession(accessToken, { maxItemCount: maxCount })
  if (!session?.id || !session?.pickerUri) {
    throw new Error('Google Photos did not return a valid picker session.')
  }

  const pickerUrl = normalizePickerUri(session.pickerUri)
  let popup = null
  const openPopup = () => {
    popup = window.open(pickerUrl, 'batches-google-photos', 'popup=yes,width=980,height=720')
    return popup
  }
  openPopup()

  const cleanup = () => {
    try { if (popup && !popup.closed) popup.close() } catch { /* cross-origin safe */ }
    deletePickerSession(accessToken, session.id)
  }

  try {
    onStatus?.({
      stage: 'picking',
      pickerUrl,
      popupBlocked: !popup,
      reopen: openPopup,
    })

    const intervalMs = parsePollIntervalMs(session.pollingConfig?.pollInterval)
    const deadline = Date.now() + parseTimeoutMs(session.pollingConfig?.timeoutIn)
    let closedChecks = 0
    let ready = Boolean(session.mediaItemsSet)

    while (!ready) {
      if (Date.now() > deadline) {
        throw new Error('Google Photos picker timed out. Try choosing your photos again.')
      }
      const popupClosed = Boolean(popup && popup.closed)
      await waitMs(popupClosed ? 750 : intervalMs, signal)
      const latest = await getPickerSession(accessToken, session.id)
      if (latest?.mediaItemsSet) {
        ready = true
        break
      }
      if (popupClosed) {
        closedChecks += 1
        // /autoclose closes the popup right after Google marks mediaItemsSet; check twice before
        // treating a closed window as cancelled.
        if (closedChecks >= 2) throw new GooglePhotosCancelledError()
      }
    }

    onStatus?.({ stage: 'listing' })
    const rawItems = await listPickedMediaItems(accessToken, session.id)
    const photoItems = rawItems.filter((item) => {
      if (item?.type && item.type !== 'PHOTO') return false
      const mime = item?.mediaFile?.mimeType || ''
      return !mime || mime.startsWith('image/')
    }).slice(0, maxCount)
    const skippedVideos = Math.max(0, rawItems.length - photoItems.length)

    const prepared = []
    for (let i = 0; i < photoItems.length; i++) {
      if (signal?.aborted) throw new GooglePhotosCancelledError()
      onStatus?.({ stage: 'downloading', done: i, total: photoItems.length })
      const item = photoItems[i]
      const file = await downloadGoogleMediaFile(accessToken, item)
      const meta = extractGoogleMediaMeta(item)
      prepared.push(await preparePhotoFile(file, meta))
    }
    onStatus?.({ stage: 'downloading', done: photoItems.length, total: photoItems.length })
    return { photos: prepared, skippedVideos }
  } finally {
    cleanup()
  }
}

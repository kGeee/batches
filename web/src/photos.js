// Shared copies of photos: small files in the private `media` bucket at
// <share_path>/{s,m,l}.heic (HEIC from the iPhone app, JPEG from the web). As in the app
// (Strewn/Services/PhotoLinks.swift), links are signed only for photos about to be shown, gathered
// into small groups, and reused until an hour before they expire. Downloaded copies are kept in
// the browser's Cache Storage under their path, which never changes for a given copy, and cleared
// on sign-out.
import { useEffect, useRef, useState } from 'react'
import { supabase } from './api.js'

const lifetime = 6 * 3600
const batchSize = 50
const maxRunning = 3
export const tierEdges = { s: 320, m: 800, l: 1800 }

/** The smallest copy that covers this many pixels, allowing 15% upscale, as the app does. */
export const fitting = (pixels) => ['s', 'm', 'l'].find((t) => tierEdges[t] * 1.15 >= pixels) ?? 'l'
export const pathFor = (photo, tier) => (photo.share_path ? `${photo.share_path}/${tier}.heic` : null)

// Format detection -------------------------------------------------------------------------------
// Object paths end in .heic for compatibility with shipped iOS builds, while web uploads store
// JPEG bytes at those paths. Sniffing the header picks the right MIME type and skips the libheif
// worker when a copy is already JPEG, PNG or WebP.

const heicBrands = new Set(['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs', 'mif1', 'msf1'])

export function detectImageMime(head) {
  const b = head instanceof Uint8Array ? head : new Uint8Array(head)
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg'
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'image/png'
  if (b.length >= 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46
      && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return 'image/webp'
  if (b.length >= 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) return 'image/gif'
  if (b.length >= 12 && b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8], b[9], b[10], b[11]).toLowerCase()
    if (brand === 'avif' || brand === 'avis') return 'image/avif'
    if (heicBrands.has(brand)) return 'image/heic'
  }
  return null
}

export async function sniffBlobMime(blob) {
  if (!blob || typeof blob.slice !== 'function') return null
  const buf = await blob.slice(0, 16).arrayBuffer()
  return detectImageMime(new Uint8Array(buf))
}

// Signed links -----------------------------------------------------------------------------------

const links = new Map()       // path -> { url, reuseUntil }
const waiting = new Map()     // path -> [resolve]
let queue = []
let running = 0
let flushTimer = null

function signedURL(path) {
  const link = links.get(path)
  if (link && link.reuseUntil > Date.now()) return Promise.resolve(link.url)
  return new Promise((resolve) => {
    if (!waiting.has(path)) { waiting.set(path, []); queue.push(path) }
    waiting.get(path).push(resolve)
    // Long enough for everything appearing in the same frame to join one request.
    flushTimer ??= setTimeout(flush, 40)
  })
}

function flush() {
  flushTimer = null
  while (running < maxRunning && queue.length) {
    const group = queue.slice(0, batchSize)
    queue = queue.slice(group.length)
    running++
    sign(group)
  }
}

async function sign(group) {
  let signed = {}
  for (let attempt = 0; attempt < 2 && !Object.keys(signed).length; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, 800))
    try {
      const { data, error } = await supabase.storage.from('media').createSignedUrls(group, lifetime)
      if (error) throw error
      // Each result names its own path, and one unsignable path doesn't sink the rest.
      for (const r of data ?? []) if (r.signedUrl && !r.error) signed[r.path] = r.signedUrl
    } catch { signed = {} }
  }
  const reuseUntil = Date.now() + (lifetime - 3600) * 1000
  for (const path of group) {
    if (signed[path]) links.set(path, { url: signed[path], reuseUntil })
    for (const resolve of waiting.get(path) ?? []) resolve(signed[path] ?? null)
    waiting.delete(path)
  }
  running--
  if (queue.length) flushTimer ??= setTimeout(flush, 40)
}

// Bytes on disk ----------------------------------------------------------------------------------

const cacheName = 'batches-photos-v1'
const cacheKey = (path) => `https://photos.batches.invalid/${path}`

async function openCache() {
  try { return 'caches' in self ? await caches.open(cacheName) : null } catch { return null }
}

/** Keeps freshly uploaded copies in local Cache Storage so the batch opens immediately. */
export async function seedPhotoCache(sharePath, copies) {
  const cache = await openCache()
  if (!cache || !sharePath || !copies) return
  await Promise.all(Object.entries(copies).map(([tier, blob]) => {
    if (!blob) return null
    const path = `${sharePath}/${tier}.heic`
    const type = blob.type || 'image/jpeg'
    return cache.put(cacheKey(path), new Response(blob, { headers: { 'Content-Type': type } })).catch(() => {})
  }))
}

async function bytes(path) {
  const cache = await openCache()
  const hit = await cache?.match(cacheKey(path)).catch(() => null)
  if (hit) return hit.blob()
  for (let attempt = 0; attempt < 2; attempt++) {
    const url = await signedURL(path)
    if (!url) return null
    const response = await fetch(url).catch(() => null)
    if (response?.ok) {
      const raw = await response.blob()
      const mime = (await sniffBlobMime(raw)) || raw.type || 'image/heic'
      const blob = raw.type === mime ? raw : new Blob([raw], { type: mime })
      cache?.put(cacheKey(path), new Response(blob, { headers: { 'Content-Type': mime } })).catch(() => {})
      return blob
    }
    // A refused link (expired, or the photo was re-shared) gets signed again once.
    links.delete(path)
    if (response && response.status !== 400 && response.status !== 403) return null
  }
  return null
}

// Showing HEIC -----------------------------------------------------------------------------------

// A 4×4 HEIC. Safari shows it; browsers that can't decode HEIC fail to load it.
const probe = 'data:image/heic;base64,AAAAKGZ0eXBoZWljAAAAAG1pZjFNaUhFTWlQcm1pYWZNaUhCaGVpYwAAArJtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAA5waXRtAAAAAAABAAAATWlpbmYAAAAAAAMAAAAVaW5mZQIAAAAAAQAAaHZjMQAAAAAVaW5mZQIAAAEAAgAAaHZjMQAAAAAVaW5mZQIAAAEAAwAARXhpZgAAAAAoaXJlZgAAAAAAAAAOYXV4bAACAAEAAQAAAA5jZHNjAAMAAQABAAABpGlwcnAAAAF7aXBjbwAAABNjb2xybmNseAACAAIABoAAAAAMY2xsaQDLAEAAAAAUaXNwZQAAAAAAAAAEAAAABAAAAAlpcm90AAAAABBwaXhpAAAAAAMICAgAAAAOcGl4aQAAAAABCAAAADdhdXhDAAAAAHVybjptcGVnOmhldmM6MjAxNTphdXhpZDoxAAAAAAwAAAAITgGlBAAB/kAAAABxaHZjQwEDcAAAALAAAAAAAB7wAPz9+PgAAAsDoAABABdAAQwB//8DcAAAAwCwAAADAAADAB5wJKEAAQAjQgEBA3AAAAMAsAAAAwAAAwAeoBQgQcCfD+Ie5FlU3AgIGAKiAAEACUQBwGFyyEBTJAAAAHFodmNDAQQIAAAAv8gAAAAAHvAA/Pz4+AAACwOgAAEAF0ABDAH//wQIAAADAL/IAAADAAAeFwJAoQABACNCAQEECAAAAwC/yAAAAwAAHsBQgQcBOwe4gXuRZVNwICAgCKIAAQAJRAHAYdLIQFMkAAAAIWlwbWEAAAAAAAAAAgABBoECAwWIhAACBQMGh4mEAAAAOmlsb2MAAAAARAAAAwABAAAAAQAAA2wAAABOAAIAAAABAAADugAAAC0AAwAAAAEAAALqAAAAggAAAAFtZGF0AAAAAAAAAQ0AAAAGRXhpZgAATU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAACQAAAAAQAAAJAAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAASgAwAEAAAAAQAAAAQAAAAAAAAASigBr6N7DxAfFfA2kSN7+n6Z9mwZeAkLMb/5qXcFH1aXUb8IITeVyEkRgw/ttuS6mOZIEljR30paNTdTFGLsPY1R6YA0GSrjh9DAAAAAKSgBr0X0HRGP4GB5goHeWd+4j5gOX1c1rXHGC/jgV+Idel7QQGUdtiw4'
let supportsHEIC = null
export function heicSupported() {
  supportsHEIC ??= new Promise((resolve) => {
    const img = new Image()
    img.onload = () => resolve(img.naturalWidth > 0)
    img.onerror = () => resolve(false)
    img.src = probe
  })
  return supportsHEIC
}

let worker = null
let nextJob = 0
const jobs = new Map()
export function decodeHEIC(blob) {
  if (!worker) {
    worker = new Worker(new URL('./heic.worker.js', import.meta.url), { type: 'module' })
    worker.onmessage = ({ data }) => {
      const job = jobs.get(data.id)
      jobs.delete(data.id)
      if (data.blob) job?.resolve(data.blob)
      else job?.reject(new Error(data.error))
    }
  }
  return blob.arrayBuffer().then((buffer) => new Promise((resolve, reject) => {
    const id = ++nextJob
    jobs.set(id, { resolve, reject })
    worker.postMessage({ id, bytes: buffer }, [buffer])
  }))
}

// Object URLs ready for <img>, by path. Older ones are let go once there are many.
const shown = new Map()
const keepShown = 400

/** A displayable URL for one copy, or null when it can't be had. */
export function displayURL(path) {
  if (shown.has(path)) {
    const hit = shown.get(path)
    shown.delete(path); shown.set(path, hit)   // most recently used last
    return hit
  }
  const promise = (async () => {
    const blob = await bytes(path)
    if (!blob) return null
    const mime = (await sniffBlobMime(blob)) || blob.type || 'image/heic'
    let shownBlob = blob.type === mime ? blob : new Blob([blob], { type: mime })
    if (mime === 'image/heic' && !(await heicSupported())) {
      shownBlob = await decodeHEIC(shownBlob)
    }
    return URL.createObjectURL(shownBlob)
  })().catch(() => null)
  shown.set(path, promise)
  promise.then((url) => { if (!url) shown.delete(path) })
  while (shown.size > keepShown) {
    const [oldest, old] = shown.entries().next().value
    shown.delete(oldest)
    old.then((url) => url && URL.revokeObjectURL(url))
  }
  return promise
}

/** For signing out: the next person in this browser shouldn't inherit these photos. */
export async function clearPhotos() {
  links.clear()
  for (const p of shown.values()) p.then((url) => url && URL.revokeObjectURL(url))
  shown.clear()
  try { if ('caches' in self) await caches.delete(cacheName) } catch { /* nothing kept */ }
}

/**
 * The image for a photo element: waits until it's near the screen, picks the copy that fits its
 * size (or `tier`), and keeps a smaller copy showing while a bigger one loads.
 */
export function usePhotoSource(photo, { tier, eager } = {}) {
  const ref = useRef(null)
  const [near, setNear] = useState(!!eager)
  const [wanted, setWanted] = useState(tier ?? 's')
  const [src, setSrc] = useState(null)
  const [state, setState] = useState('idle')   // idle | loading | ready | failed

  useEffect(() => {
    if (eager || !ref.current) return
    const io = new IntersectionObserver(([e]) => setNear(e.isIntersecting), { rootMargin: '600px 300px' })
    io.observe(ref.current)
    return () => io.disconnect()
  }, [eager])

  useEffect(() => {
    if (tier || !ref.current) return
    const ro = new ResizeObserver(([e]) => {
      const { width, height } = e.contentRect
      const pixels = Math.max(width, height) * (window.devicePixelRatio || 1)
      // Only ever step up: a smaller copy than one already wanted adds nothing.
      setWanted((w) => { const t = fitting(pixels); return tierEdges[t] > tierEdges[w] ? t : w })
    })
    ro.observe(ref.current)
    return () => ro.disconnect()
  }, [tier])

  useEffect(() => {
    const path = pathFor(photo, tier ?? wanted)
    if (!near || !path) return
    let live = true
    setState((s) => (s === 'ready' ? s : 'loading'))
    displayURL(path).then((url) => {
      if (!live) return
      if (url) { setSrc(url); setState('ready') } else setState((s) => (s === 'ready' ? s : 'failed'))
    })
    return () => { live = false }
  }, [photo.id, photo.share_path, near, wanted, tier]) // eslint-disable-line react-hooks/exhaustive-deps

  return { ref, src, state: photo.share_path ? state : 'missing' }
}

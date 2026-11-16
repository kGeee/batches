// Print files, made in the browser: each page is drawn onto a canvas at 300 dpi with the same
// geometry render.jsx uses on screen, then pages become a PDF with trim and bleed boxes. Drawing
// to pixels means the printer needs none of our fonts.
import { PDFDocument } from 'pdf-lib'
import { displayURL, pathFor } from '../photos.js'
import { captionFamily, fontFamily } from '../look.js'
import { aspectOf, coverLayout, coverPhotoBox, formatOf, framePadding, lineHeight, printBox, spineInches } from './format.js'
import { backgroundColor, chapterOf, cloths, isDark, photoCredit, spillInto, textColor } from './doc.js'

export const dpi = 300
// The bucket takes files up to 50 MB; leave room.
const fileBudget = 45 * 1024 * 1024
const mono = 'ui-monospace, "SF Mono", Menlo, Consolas, monospace'
const family = (font) => (font === 'mono' ? mono : fontFamily(font))
const frameColors = { whiteBorder: '#ffffff', galleryMat: '#ffffff', polaroid: '#fdfcf8', thinBlack: '#111111' }

/** The largest shared copy of a photo, decoded and ready to draw. */
function loader() {
  const cache = new Map()
  return (photo) => {
    const path = photo && pathFor(photo, 'l')
    if (!path) return Promise.resolve(null)
    if (!cache.has(path)) {
      cache.set(path, displayURL(path).then((url) => url && new Promise((resolve) => {
        const img = new Image()
        img.onload = () => resolve(img)
        img.onerror = () => resolve(null)
        img.src = url
      })))
    }
    return cache.get(path)
  }
}

function weave(ctx, x, y, w, h, unit, color) {
  ctx.save()
  ctx.fillStyle = color
  const step = unit / 260
  for (let yy = y; yy < y + h; yy += step * 3) ctx.fillRect(x, yy, w, step)
  for (let xx = x; xx < x + w; xx += step * 4) ctx.fillRect(xx, y, step, h)
  ctx.restore()
}

function drawText(ctx, item, bg, U) {
  ctx.save()
  ctx.translate(item.x * U, item.y * U)
  ctx.rotate((item.rotation * Math.PI) / 180)
  ctx.font = `${item.italic ? 'italic ' : ''}${item.size * U}px ${family(item.font)}`
  if ('letterSpacing' in ctx) ctx.letterSpacing = item.font === 'mono' ? `${0.12 * item.size * U}px` : '0px'
  ctx.fillStyle = textColor(item.color, bg)
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'
  const lines = item.text.split('\n')
  const lh = lineHeight * item.size * U
  lines.forEach((line, i) => ctx.fillText(line, 0, (i - (lines.length - 1) / 2) * lh))
  ctx.restore()
}

function drawPhoto(ctx, item, img, { photo, caption, captionFont, credit, bg }, U) {
  const box = printBox(item, item.aspect, item.frame)
  const [t, , b, l] = framePadding(item.frame).map((f) => f * item.w * U)
  ctx.save()
  ctx.translate(item.x * U, item.y * U)
  ctx.rotate((item.rotation * Math.PI) / 180)
  const x0 = (-box.w / 2) * U, y0 = (-box.h / 2) * U
  if (item.frame !== 'none') {
    ctx.save()
    ctx.shadowColor = 'rgba(0, 0, 0, .18)'
    ctx.shadowBlur = 0.012 * U
    ctx.shadowOffsetY = 0.004 * U
    ctx.fillStyle = frameColors[item.frame]
    ctx.fillRect(x0, y0, box.w * U, box.h * U)
    ctx.restore()
  }
  const ix = x0 + l, iy = y0 + t, iw = box.imageW * U, ih = box.imageH * U
  if (img) ctx.drawImage(img, ix, iy, iw, ih)
  else { ctx.fillStyle = 'rgba(128, 120, 104, .3)'; ctx.fillRect(ix, iy, iw, ih) }
  if (item.frame === 'galleryMat') {
    ctx.strokeStyle = 'rgba(0, 0, 0, .18)'
    ctx.lineWidth = 0.0012 * U
    ctx.strokeRect(ix - ctx.lineWidth / 2, iy - ctx.lineWidth / 2, iw + ctx.lineWidth, ih + ctx.lineWidth)
  }
  if (item.frame === 'polaroid' && caption) {
    ctx.font = `${Math.min((b / U) * 0.36, 0.03) * U}px ${captionFamily(captionFont)}`
    ctx.fillStyle = '#2b2b2b'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(caption, 0, y0 + box.h * U - b / 2, iw)
  }
  if (credit) {
    ctx.font = `${0.015 * U}px ${mono}`
    if ('letterSpacing' in ctx) ctx.letterSpacing = `${0.0015 * U}px`
    ctx.fillStyle = isDark(bg) ? 'rgba(170, 164, 152, .9)' : 'rgba(110, 104, 92, .95)'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    ctx.fillText(credit.toUpperCase(), 0, y0 + box.h * U + 0.01 * U)
  }
  ctx.restore()
  return photo
}

/** Draws page `index` onto a square canvas that includes the bleed on every side. */
export async function drawPage(canvas, doc, index, { photos, batches, me }, load) {
  const format = formatOf(doc)
  const U = format.trimInches * dpi
  const off = format.bleedInches * dpi
  const ctx = canvas.getContext('2d')
  const page = doc.pages[index]
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.fillStyle = backgroundColor(page.background)
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  if (page.background === 'linen') weave(ctx, 0, 0, canvas.width, canvas.height, U, 'rgba(70, 56, 34, .045)')
  const items = [...spillInto(doc, index).map((i) => ({ ...i, x: i.x - 1, spill: true })), ...page.items].sort((a, b) => a.z - b.z)
  const imgs = await Promise.all(items.map((i) => (i.kind === 'photo' ? load(photos[i.photo]) : null)))
  const chapter = chapterOf(doc, page.chapter)
  ctx.translate(off, off)
  items.forEach((item, n) => {
    if (item.kind === 'text') return drawText(ctx, item, page.background, U)
    const photo = photos[item.photo]
    drawPhoto(ctx, item, imgs[n], {
      photo, caption: photo?.caption, captionFont: chapter?.font, bg: page.background,
      credit: doc.credits && !item.spill ? photoCredit(photo, batches[chapter?.batch], me) : '',
    }, U)
  })
}

/** The cover as one flat sheet: back, spine and front, with bleed all round. */
export async function drawCover(canvas, doc, { photos }, load) {
  const format = formatOf(doc)
  const U = format.trimInches * dpi
  const off = format.bleedInches * dpi
  const spine = spineInches(doc.pages.length) * dpi
  const cloth = cloths[doc.cover.cloth] ?? cloths.oat
  const ctx = canvas.getContext('2d')
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.fillStyle = cloth.color
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  weave(ctx, 0, 0, canvas.width, canvas.height, U, 'rgba(0, 0, 0, .035)')
  ctx.fillStyle = cloth.ink
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'

  // Back
  ctx.save()
  ctx.globalAlpha = 0.7
  ctx.font = `${0.018 * U}px ${mono}`
  if ('letterSpacing' in ctx) ctx.letterSpacing = `${0.003 * U}px`
  ctx.fillText('MADE WITH BATCHES', off + U / 2, off + 0.92 * U)
  ctx.restore()

  // Spine, read top to bottom
  ctx.save()
  ctx.translate(off + U + spine / 2, off + U / 2)
  ctx.rotate(Math.PI / 2)
  ctx.font = `${Math.min(spine * 0.42, 0.03 * U)}px ${family(doc.cover.font)}`
  ctx.fillText(doc.cover.title || doc.title, 0, 0, U * 0.8)
  ctx.restore()

  // Front
  const fx = off + U + spine, fy = off
  const photo = photos[doc.cover.photo]
  const img = await load(photo)
  const box = coverPhotoBox(photo ? aspectOf(photo) : 1)
  ctx.save()
  ctx.shadowColor = 'rgba(0, 0, 0, .3)'
  ctx.shadowBlur = 0.01 * U
  ctx.shadowOffsetY = 0.003 * U
  const px = fx + (box.x - box.w / 2) * U, py = fy + (box.y - box.h / 2) * U
  if (img) ctx.drawImage(img, px, py, box.w * U, box.h * U)
  ctx.restore()
  ctx.font = `${coverLayout.titleSize * U}px ${family(doc.cover.font)}`
  ctx.fillText(doc.cover.title || doc.title, fx + U / 2, fy + coverLayout.titleY * U, U * 0.88)
  if (doc.byline) {
    ctx.save()
    ctx.globalAlpha = 0.8
    ctx.font = `${coverLayout.bylineSize * U}px ${mono}`
    if ('letterSpacing' in ctx) ctx.letterSpacing = `${0.14 * coverLayout.bylineSize * U}px`
    ctx.fillText(doc.byline.toUpperCase(), fx + U / 2, fy + coverLayout.bylineY * U, U * 0.88)
    ctx.restore()
  }
}

/** A JPEG no bigger than `budget` bytes if it can be helped. */
async function encode(canvas, budget) {
  let blob
  for (const q of [0.88, 0.8, 0.7, 0.6]) {
    blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', q))
    if (blob.size <= budget) break
  }
  return new Uint8Array(await blob.arrayBuffer())
}

const pts = (inches) => inches * 72

/** The inside pages as one PDF. `onProgress(done, total)` after each page. */
export async function interiorPDF(doc, data, onProgress = () => {}) {
  const format = formatOf(doc)
  const load = loader()
  const side = Math.round((format.trimInches + 2 * format.bleedInches) * dpi)
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = side
  if (document.fonts?.ready) await document.fonts.ready
  const pdf = await PDFDocument.create()
  pdf.setTitle(doc.title)
  pdf.setCreator('Batches')
  const size = pts(format.trimInches + 2 * format.bleedInches)
  const b = pts(format.bleedInches), trim = pts(format.trimInches)
  const budget = fileBudget / doc.pages.length
  for (let i = 0; i < doc.pages.length; i++) {
    await drawPage(canvas, doc, i, data, load)
    const image = await pdf.embedJpg(await encode(canvas, budget))
    const page = pdf.addPage([size, size])
    page.drawImage(image, { x: 0, y: 0, width: size, height: size })
    page.setBleedBox(0, 0, size, size)
    page.setTrimBox(b, b, trim, trim)
    onProgress(i + 1, doc.pages.length)
  }
  return new Blob([await pdf.save()], { type: 'application/pdf' })
}

export async function coverPDF(doc, data) {
  const format = formatOf(doc)
  const load = loader()
  const spine = spineInches(doc.pages.length)
  const wIn = 2 * format.trimInches + spine + 2 * format.bleedInches
  const hIn = format.trimInches + 2 * format.bleedInches
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(wIn * dpi)
  canvas.height = Math.round(hIn * dpi)
  if (document.fonts?.ready) await document.fonts.ready
  await drawCover(canvas, doc, data, load)
  const pdf = await PDFDocument.create()
  pdf.setTitle(`${doc.title}: cover`)
  pdf.setCreator('Batches')
  const image = await pdf.embedJpg(await encode(canvas, fileBudget))
  const page = pdf.addPage([pts(wIn), pts(hIn)])
  page.drawImage(image, { x: 0, y: 0, width: pts(wIn), height: pts(hIn) })
  page.setBleedBox(0, 0, pts(wIn), pts(hIn))
  page.setTrimBox(pts(format.bleedInches), pts(format.bleedInches), pts(wIn - 2 * format.bleedInches), pts(format.trimInches))
  return new Blob([await pdf.save()], { type: 'application/pdf' })
}

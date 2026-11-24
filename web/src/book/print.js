// The print file, made in the browser: each page is drawn onto a canvas at 300 dpi with the same
// geometry render.jsx uses on screen, then everything becomes one PDF with trim and bleed boxes,
// laid out the way Gelato takes a photo book: the cover sheet, a blank endpaper, the pages, and a
// blank last page. Drawing to pixels means the printer needs none of our fonts.
import { PDFDocument, rgb } from 'pdf-lib'
import { displayURL, pathFor } from '../photos.js'
import { captionFamily, fontFamily } from '../look.js'
import { aspectOf, coverLayout, coverPhotoBox, coverSheet, formatOf, framePadding, lineHeight, printBox } from './format.js'
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

/**
 * The cover as one flat sheet: back, spine and front where `sheet` (from coverSheet, in inches)
 * puts them. Cloth runs across the whole sheet, wrap and hinges included, so nothing white shows
 * where it folds round the boards.
 */
export async function drawCover(canvas, doc, { photos }, load, sheet) {
  const px = (inches) => inches * dpi
  const cloth = cloths[doc.cover.cloth] ?? cloths.oat
  const ctx = canvas.getContext('2d')
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.fillStyle = cloth.color
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  weave(ctx, 0, 0, canvas.width, canvas.height, px(sheet.front.w), 'rgba(0, 0, 0, .035)')
  ctx.fillStyle = cloth.ink
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'

  // Positions on the back and front are in units of that side's width, centred top to bottom.
  const side = (r) => ({ U: px(r.w), x: px(r.x), y: px(r.y) + (px(r.h) - px(r.w)) / 2 })

  // Back
  const back = side(sheet.back)
  ctx.save()
  ctx.globalAlpha = 0.7
  ctx.font = `${0.018 * back.U}px ${mono}`
  if ('letterSpacing' in ctx) ctx.letterSpacing = `${0.003 * back.U}px`
  ctx.fillText('MADE WITH BATCHES', back.x + back.U / 2, back.y + 0.92 * back.U)
  ctx.restore()

  // Spine, read top to bottom
  const front = side(sheet.front)
  const spineW = px(sheet.spine.w), spineH = px(sheet.spine.h)
  ctx.save()
  ctx.translate(px(sheet.spine.x) + spineW / 2, px(sheet.spine.y) + spineH / 2)
  ctx.rotate(Math.PI / 2)
  ctx.font = `${Math.min(spineW * 0.42, 0.03 * front.U)}px ${family(doc.cover.font)}`
  ctx.fillText(doc.cover.title || doc.title, 0, 0, spineH * 0.8)
  ctx.restore()

  // Front
  const { U, x: fx, y: fy } = front
  const photo = photos[doc.cover.photo]
  const img = await load(photo)
  const box = coverPhotoBox(photo ? aspectOf(photo) : 1)
  ctx.save()
  ctx.shadowColor = 'rgba(0, 0, 0, .3)'
  ctx.shadowBlur = 0.01 * U
  ctx.shadowOffsetY = 0.003 * U
  const photoX = fx + (box.x - box.w / 2) * U, photoY = fy + (box.y - box.h / 2) * U
  if (img) ctx.drawImage(img, photoX, photoY, box.w * U, box.h * U)
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

/**
 * The whole book as one PDF, in the order Gelato asks for: page 1 is the cover sheet (back, spine
 * and front), page 2 a blank endpaper, then every page of the book, then a blank last page. So a
 * 30-page book is a 33-page file. `printer` is Gelato's cover measurements for this page count;
 * without them the cover is sized from an estimate. `onProgress(step, done, total)` as it goes.
 */
export async function bookPDF(doc, data, { printer = null, onProgress = () => {} } = {}) {
  const format = formatOf(doc)
  const load = loader()
  if (document.fonts?.ready) await document.fonts.ready
  const pdf = await PDFDocument.create()
  pdf.setTitle(doc.title)
  pdf.setCreator('Batches')
  // The cover sheet is about two and a half pages of pixels; budget it as three.
  const budget = fileBudget / (doc.pages.length + 3)

  onProgress('cover', 0, 1)
  const sheet = coverSheet(format, doc.pages.length, printer)
  const coverCanvas = document.createElement('canvas')
  coverCanvas.width = Math.round(sheet.w * dpi)
  coverCanvas.height = Math.round(sheet.h * dpi)
  await drawCover(coverCanvas, doc, data, load, sheet)
  const coverImage = await pdf.embedJpg(await encode(coverCanvas, budget * 3))
  const cover = pdf.addPage([pts(sheet.w), pts(sheet.h)])
  cover.drawImage(coverImage, { x: 0, y: 0, width: pts(sheet.w), height: pts(sheet.h) })
  // The whole sheet is printed and wrapped; the printer's template already counts its edges.
  cover.setBleedBox(0, 0, pts(sheet.w), pts(sheet.h))
  cover.setTrimBox(0, 0, pts(sheet.w), pts(sheet.h))
  onProgress('cover', 1, 1)

  const size = pts(format.trimInches + 2 * format.bleedInches)
  const b = pts(format.bleedInches), trim = pts(format.trimInches)
  const inside = (image) => {
    const page = pdf.addPage([size, size])
    if (image) page.drawImage(image, { x: 0, y: 0, width: size, height: size })
    else page.drawRectangle({ x: 0, y: 0, width: size, height: size, color: rgb(1, 1, 1) })
    page.setBleedBox(0, 0, size, size)
    page.setTrimBox(b, b, trim, trim)
  }

  inside(null) // endpaper
  const side = Math.round((format.trimInches + 2 * format.bleedInches) * dpi)
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = side
  for (let i = 0; i < doc.pages.length; i++) {
    await drawPage(canvas, doc, i, data, load)
    inside(await pdf.embedJpg(await encode(canvas, budget)))
    onProgress('pages', i + 1, doc.pages.length)
  }
  inside(null) // last page, against the inside of the back cover

  return { blob: new Blob([await pdf.save()], { type: 'application/pdf' }), sheet }
}

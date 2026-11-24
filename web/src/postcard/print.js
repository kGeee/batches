// A postcard's two print files, made in the browser like a book's: each side is drawn onto a canvas
// at 300 dpi, then wrapped in a one-page PDF with its trim and bleed boxes. Lob prints whatever is
// on the page, so the printer needs none of our fonts.
import { PDFDocument } from 'pdf-lib'
import { displayURL, pathFor } from '../photos.js'
import { fontFamily } from '../look.js'
import { addressBox, card, frontPhotoBox, messageBox, wrapLines } from './format.js'

const hand = '"Bradley Hand", Noteworthy, "Segoe Print", cursive'
const mono = 'ui-monospace, "SF Mono", Menlo, Consolas, monospace'

/** The largest shared copy of a photo, decoded and ready to draw. */
export function loadPhoto(photo) {
  const path = photo && pathFor(photo, 'l')
  if (!path) return Promise.resolve(null)
  return displayURL(path).then((url) => url && new Promise((resolve) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = () => resolve(null)
    img.src = url
  }))
}

function sized(canvas, scale) {
  canvas.width = Math.round(card.sheet.w * scale)
  canvas.height = Math.round(card.sheet.h * scale)
  const ctx = canvas.getContext('2d')
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  return ctx
}

/** The front: the whole photo on white, turned a quarter if it's portrait. `scale` is pixels per inch. */
export function drawFront(canvas, img, aspect, scale = card.dpi) {
  const ctx = sized(canvas, scale)
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  const box = frontPhotoBox(aspect)
  ctx.save()
  ctx.translate(box.cx * scale, box.cy * scale)
  if (box.turned) ctx.rotate(-Math.PI / 2)
  const w = box.w * scale, h = box.h * scale
  if (img) ctx.drawImage(img, -w / 2, -h / 2, w, h)
  else { ctx.fillStyle = 'rgba(128, 120, 104, .3)'; ctx.fillRect(-w / 2, -h / 2, w, h) }
  ctx.restore()
}

/**
 * The back: the message on the left, who it's from under it, a rule, and the address block left
 * blank for Lob. Returns false if the message doesn't fit at the smallest size.
 */
export function drawBack(canvas, { message, from }, scale = card.dpi) {
  const ctx = sized(canvas, scale)
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  const box = messageBox()
  const address = addressBox()

  // A thin rule between the message and the address side, kept clear of the ink-free block.
  ctx.strokeStyle = 'rgba(0, 0, 0, .25)'
  ctx.lineWidth = 0.008 * scale
  const ruleX = (box.x + box.w + address.x) / 2
  ctx.beginPath()
  ctx.moveTo(ruleX * scale, box.y * scale)
  ctx.lineTo(ruleX * scale, (box.y + box.h) * scale)
  ctx.stroke()

  // The biggest size the message fits at, from 0.2 in down to 0.12 in.
  const room = box.h - 0.45
  let size = 0.2, lines = []
  for (; size >= 0.12; size -= 0.01) {
    ctx.font = `${size * scale}px ${hand}`
    lines = wrapLines(message.trim(), box.w * scale, (s) => ctx.measureText(s).width)
    if (lines.length * size * 1.3 <= room) break
  }
  const fits = size >= 0.12
  ctx.fillStyle = '#1d1b18'
  ctx.textBaseline = 'top'
  lines.forEach((line, i) => ctx.fillText(line, box.x * scale, (box.y + i * size * 1.3) * scale))

  ctx.font = `${0.14 * scale}px ${fontFamily('classic')}`
  ctx.fillText(from, box.x * scale, (box.y + box.h - 0.32) * scale)
  ctx.fillStyle = 'rgba(0, 0, 0, .45)'
  ctx.font = `${0.065 * scale}px ${mono}`
  if ('letterSpacing' in ctx) ctx.letterSpacing = `${0.012 * scale}px`
  ctx.fillText('MADE WITH BATCHES', box.x * scale, (box.y + box.h - 0.1) * scale)
  return fits
}

async function onePagePDF(canvas, type) {
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, type, 0.92))
  const bytes = new Uint8Array(await blob.arrayBuffer())
  const pdf = await PDFDocument.create()
  const image = type === 'image/png' ? await pdf.embedPng(bytes) : await pdf.embedJpg(bytes)
  const pt = (inches) => inches * 72
  const page = pdf.addPage([pt(card.sheet.w), pt(card.sheet.h)])
  page.drawImage(image, { x: 0, y: 0, width: pt(card.sheet.w), height: pt(card.sheet.h) })
  page.setBleedBox(0, 0, pt(card.sheet.w), pt(card.sheet.h))
  page.setTrimBox(pt(card.bleed), pt(card.bleed), pt(card.trim.w), pt(card.trim.h))
  return new Blob([await pdf.save()], { type: 'application/pdf' })
}

/** Both print files: `{ front, back }` as PDF blobs, 6.25 x 4.25 in, landscape. */
export async function postcardPDFs({ photo, img, message, from }) {
  const canvas = document.createElement('canvas')
  drawFront(canvas, img, photo.pixel_width / photo.pixel_height)
  const front = await onePagePDF(canvas, 'image/jpeg')
  drawBack(canvas, { message, from })
  const back = await onePagePDF(canvas, 'image/png')
  return { front, back }
}

// What would go wrong at the printer, checked before a book can be ordered.
import { dpiGood, dpiLowest, effectiveDPI, formatOf, printBox, safeMargin, turnedBounds } from './format.js'

/**
 * Problems in a book. `block` stops an order; `warn` is worth a look but prints.
 * Each problem names the page (0-based) and the item it's about.
 */
export function preflight(doc, photosByID) {
  const format = formatOf(doc)
  const m = safeMargin(format)
  const problems = []
  const add = (level, page, item, text) => problems.push({ level, page, item, text })
  const n = doc.pages.length
  if (n < format.minPages) add('block', null, null, `A book needs at least ${format.minPages} pages.`)
  if (n > format.maxPages) add('block', null, null, `A book can have at most ${format.maxPages} pages.`)
  if (n % 2) add('block', null, null, 'A book needs an even number of pages.')
  if (!doc.cover?.photo || !photosByID[doc.cover.photo]) add('block', null, null, 'Choose a photo for the cover.')

  let empty = 0
  doc.pages.forEach((page, p) => {
    if (!page.items.length) empty++
    const spansRight = page.items.some((i) => i.x + (i.w ?? 0) / 2 > 1)
    for (const item of page.items) {
      if (item.kind === 'text') {
        if (!item.text.trim()) continue
        const halfW = (item.text.length * item.size * 0.28), halfH = item.size * 0.6
        if (item.x - halfW < m - 0.01 || item.x + halfW > 1 - m + 0.01 || item.y - halfH < m - 0.01 || item.y + halfH > 1 - m + 0.01) {
          add('warn', p, item.id, 'Words this close to the edge may be trimmed.')
        }
        continue
      }
      const photo = photosByID[item.photo]
      if (!photo) { add('block', p, item.id, 'A photo here is no longer shared with you.'); continue }
      const box = printBox(item, item.aspect, item.frame)
      const dpi = effectiveDPI(photo, box.imageW, format)
      if (dpi < dpiLowest) add('block', p, item.id, `Printed this big, this photo would look blurry (${Math.round(dpi)} dpi). Make it smaller.`)
      else if (dpi < dpiGood) add('warn', p, item.id, `This photo may look soft printed this big (${Math.round(dpi)} dpi).`)
      const b = turnedBounds(item.x, item.y, box.w, box.h, item.rotation)
      const right = spansRight ? 2 - m : 1 - m
      const bleeds = b.left <= 0.002 && b.right >= right + m - 0.002
      if (!bleeds && (b.left < m - 0.005 || b.right > right + 0.005 || b.top < m - 0.005 || b.bottom > 1 - m + 0.005)) {
        add('warn', p, item.id, 'Part of this photo is outside the safe area and may be trimmed.')
      }
    }
  })
  if (empty > n / 3) add('warn', null, null, `${empty} pages are blank.`)
  return { problems, blocked: problems.some((x) => x.level === 'block') }
}

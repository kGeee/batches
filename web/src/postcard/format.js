// What a mailed postcard is physically, and where things go on it. Lob prints and mails it.
//
// Lob's 4x6 postcard is a 6.25 x 4.25 in sheet, landscape, trimmed to 6 x 4 in, with 1/8 in of
// bleed on every side. On the back, Lob prints the address and postage in a block at the bottom
// right that must stay free of ink. Everything here is in inches from the sheet's top left.

export const card = {
  size: '4x6',
  trim: { w: 6, h: 4 },
  bleed: 0.125,
  sheet: { w: 6.25, h: 4.25 },
  // Keep anything important this far inside the trim.
  safe: 0.125,
  dpi: 300,
  // Lob's ink-free address block for 4x6, measured from the sheet's bottom right, bleed included.
  addressBlock: { w: 3.2835, h: 2.375, right: 0.275, bottom: 0.25 },
  messageMax: 350,
  // What a card costs us to have Lob print and mail first class on its Developer plan (Nov 2026).
  costCents: 91,
}

/** The address block as a box on the back. */
export function addressBox() {
  const a = card.addressBlock
  return { x: card.sheet.w - a.right - a.w, y: card.sheet.h - a.bottom - a.h, w: a.w, h: a.h }
}

/** The white border round the photo on the front, past the trim. */
export const border = 0.22

/**
 * Where the photo goes on the front: whole, never cropped, as large as fits inside the border.
 * A portrait photo is turned a quarter so it fills the landscape card; `turned` says so, and
 * `w` and `h` are the photo's own width and height before turning.
 */
export function frontPhotoBox(aspect) {
  const inset = card.bleed + border
  const roomW = card.sheet.w - 2 * inset, roomH = card.sheet.h - 2 * inset
  const turned = aspect < 1
  const shown = turned ? 1 / aspect : aspect           // width ÷ height as it sits on the card
  let w = roomW, h = roomW / shown
  if (h > roomH) { h = roomH; w = roomH * shown }
  const cx = card.sheet.w / 2, cy = card.sheet.h / 2
  return { cx, cy, boxW: w, boxH: h, w: turned ? h : w, h: turned ? w : h, turned }
}

/** Where the message is written on the back: left of the address block, inside the safe area. */
export function messageBox() {
  const inset = card.bleed + card.safe + 0.05
  const right = addressBox().x - 0.2
  return { x: inset, y: inset, w: right - inset, h: card.sheet.h - 2 * inset - 0.3 }
}

const states = new Set(('AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY ' +
  'NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY AS GU MP PR VI AA AE AP').split(' '))

/** A US address tidied for mailing, and what's wrong with it. Lob checks it again when it's sent. */
export function cleanAddress(a) {
  const t = (s) => String(s ?? '').replace(/\s+/g, ' ').trim()
  const out = {
    name: t(a.name), line1: t(a.line1), line2: t(a.line2),
    city: t(a.city), state: t(a.state).toUpperCase(), zip: t(a.zip),
  }
  const problems = []
  if (!out.name) problems.push('Add who it\'s for.')
  else if (out.name.length > 40) problems.push('Keep the name to 40 characters.')
  if (!out.line1) problems.push('Add the street address.')
  else if (out.line1.length > 64 || out.line2.length > 64) problems.push('Keep each address line to 64 characters.')
  if (!out.city) problems.push('Add the city.')
  if (!states.has(out.state)) problems.push('Use the two-letter state, like CA.')
  if (!/^\d{5}(-\d{4})?$/.test(out.zip)) problems.push('Use a five-digit ZIP code.')
  return { address: out, problems }
}

/**
 * Lines of the message that fit `width`, given a way to measure text. Breaks at spaces and keeps
 * the writer's own line breaks; a word too long for a line is split.
 */
export function wrapLines(text, width, measure) {
  const lines = []
  for (const para of String(text).split('\n')) {
    let line = ''
    for (const word of para.split(' ')) {
      const next = line ? `${line} ${word}` : word
      if (measure(next) <= width) { line = next; continue }
      if (line) lines.push(line)
      line = word
      while (measure(line) > width && line.length > 1) {
        let cut = line.length - 1
        while (cut > 1 && measure(line.slice(0, cut)) > width) cut--
        lines.push(line.slice(0, cut))
        line = line.slice(cut)
      }
    }
    lines.push(line)
  }
  return lines
}

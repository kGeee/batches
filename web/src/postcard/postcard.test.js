import { describe, expect, it } from 'vitest'
import { addressBox, card, cleanAddress, frontPhotoBox, messageBox, wrapLines } from './format.js'

const inside = (box, l, t, r, b) => box.x >= l - 1e-9 && box.y >= t - 1e-9 && box.x + box.w <= r + 1e-9 && box.y + box.h <= b + 1e-9
const safe = [card.bleed + card.safe, card.bleed + card.safe, card.sheet.w - card.bleed - card.safe, card.sheet.h - card.bleed - card.safe]

describe('postcard front', () => {
  for (const aspect of [3 / 2, 4 / 3, 1, 2 / 3, 3 / 4, 16 / 9, 9 / 16, 3]) {
    it(`shows a ${aspect.toFixed(2)} photo whole, inside the safe area`, () => {
      const p = frontPhotoBox(aspect)
      expect(p.w / p.h).toBeCloseTo(aspect, 6)
      const shown = { x: p.cx - p.boxW / 2, y: p.cy - p.boxH / 2, w: p.boxW, h: p.boxH }
      expect(inside(shown, ...safe)).toBe(true)
      expect(p.turned).toBe(aspect < 1)
    })
  }
  it('fills the card edge to edge in one direction', () => {
    const p = frontPhotoBox(3 / 2)
    const roomW = card.sheet.w - 2 * (card.bleed + 0.22), roomH = card.sheet.h - 2 * (card.bleed + 0.22)
    expect(Math.max(p.boxW / roomW, p.boxH / roomH)).toBeCloseTo(1, 6)
  })
})

describe('postcard back', () => {
  it('puts Lob\'s address block where Lob says, bleed included', () => {
    const a = addressBox()
    expect(card.sheet.w - (a.x + a.w)).toBeCloseTo(0.275, 6)
    expect(card.sheet.h - (a.y + a.h)).toBeCloseTo(0.25, 6)
    expect([a.w, a.h]).toEqual([3.2835, 2.375])
  })
  it('keeps the message inside the safe area and clear of the address block', () => {
    const m = messageBox(), a = addressBox()
    expect(inside(m, ...safe)).toBe(true)
    expect(m.x + m.w).toBeLessThan(a.x)
    expect(m.w).toBeGreaterThan(2)
  })
})

describe('addresses', () => {
  it('tidies a good one', () => {
    const { address, problems } = cleanAddress({ name: ' Ana  Ruiz ', line1: '1 Main St', city: 'Oakland', state: 'ca', zip: '94612-1234' })
    expect(problems).toEqual([])
    expect(address).toMatchObject({ name: 'Ana Ruiz', state: 'CA', zip: '94612-1234', line2: '' })
  })
  it('says what\'s missing or wrong', () => {
    expect(cleanAddress({}).problems).toHaveLength(5)
    expect(cleanAddress({ name: 'A', line1: '1', city: 'B', state: 'XX', zip: '94612' }).problems).toEqual(['Use the two-letter state, like CA.'])
    expect(cleanAddress({ name: 'A', line1: '1', city: 'B', state: 'NY', zip: '1001' }).problems).toEqual(['Use a five-digit ZIP code.'])
  })
})

describe('wrapping the message', () => {
  const measure = (s) => s.length
  it('breaks at spaces and keeps the writer\'s line breaks', () => {
    expect(wrapLines('one two three\nfour', 8, measure)).toEqual(['one two', 'three', 'four'])
  })
  it('splits a word too long for a line', () => {
    expect(wrapLines('abcdefghij', 4, measure)).toEqual(['abcd', 'efgh', 'ij'])
  })
})

// Undo and redo for the book editor, as whole-document snapshots: documents are small and every
// edit already makes a new one.
import { useCallback, useRef, useState } from 'react'

export const historyLimit = 100
const coalesceMs = 600

/** A plain history: past, present, future. `key` merges a run of the same edit (a drag) into one step. */
export function push(h, next, key = null, now = Date.now()) {
  if (next === h.present) return h
  if (key && h.key === key && now - h.at < coalesceMs) return { ...h, present: next, at: now }
  return { past: [...h.past, h.present].slice(-historyLimit), present: next, future: [], key, at: now }
}
export const undo = (h) => (h.past.length ? { past: h.past.slice(0, -1), present: h.past[h.past.length - 1], future: [h.present, ...h.future], key: null, at: 0 } : h)
export const redo = (h) => (h.future.length ? { past: [...h.past, h.present], present: h.future[0], future: h.future.slice(1), key: null, at: 0 } : h)
export const start = (present) => ({ past: [], present, future: [], key: null, at: 0 })

export function useHistory(initial) {
  const [h, setH] = useState(() => start(initial))
  const ref = useRef(h)
  ref.current = h
  const apply = useCallback((fn, key) => setH((cur) => push(cur, typeof fn === 'function' ? fn(cur.present) : fn, key)), [])
  return {
    doc: h.present,
    canUndo: h.past.length > 0,
    canRedo: h.future.length > 0,
    apply,
    undo: useCallback(() => setH(undo), []),
    redo: useCallback(() => setH(redo), []),
    reset: useCallback((doc) => setH(start(doc)), []),
    current: () => ref.current.present,
  }
}

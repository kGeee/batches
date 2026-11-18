import { useEffect, useState } from 'react'
import { usePhotoSource } from './photos.js'
import { captionFamily, insets, pilePlacement, pileStack } from './look.js'

// Routes -----------------------------------------------------------------------------------------
// /app · /app/friends · /app/people · /app/u/<handle> · /b/<batch>[?photo=<photo>]
// /app/books · /app/books/new[?b=<batch>,…] · /app/books/<book>[/pages|/cover|/order|/preview]
// /b/ links are the same ones the iPhone app shares, so a batch's address works in both.

export function parseRoute(pathname, search) {
  const photo = new URLSearchParams(search).get('photo')
  const b = pathname.match(/^\/b\/([^/]+)\/?$/)
  if (b) return { page: 'batch', id: decodeURIComponent(b[1]).toLowerCase(), photo: photo?.toLowerCase() ?? null }
  const rest = pathname.replace(/^\/app\/?/, '').split('/').filter(Boolean)
  if (rest[0] === 'friends') return { page: 'friends' }
  if (rest[0] === 'notifications') return { page: 'notifications' }
  if (rest[0] === 'people') return { page: 'people' }
  if (rest[0] === 'u' && rest[1]) return { page: 'profile', handle: decodeURIComponent(rest[1]) }
  if (rest[0] === 'books') {
    if (!rest[1]) return { page: 'books' }
    if (rest[1] === 'new') return { page: 'newbook', picked: (new URLSearchParams(search).get('b') ?? '').split(',').filter(Boolean) }
    return { page: 'book', id: rest[1].toLowerCase(), view: ['pages', 'cover', 'order', 'preview'].includes(rest[2]) ? rest[2] : 'edit' }
  }
  return { page: 'desk' }
}

export function useLocation() {
  const read = () => ({ pathname: window.location.pathname, search: window.location.search })
  const [loc, setLoc] = useState(read)
  useEffect(() => {
    const on = () => setLoc(read())
    window.addEventListener('popstate', on)
    window.addEventListener('batches:navigate', on)
    return () => { window.removeEventListener('popstate', on); window.removeEventListener('batches:navigate', on) }
  }, [])
  return loc
}

export function go(url, { replace = false, state = {} } = {}) {
  window.history[replace ? 'replaceState' : 'pushState']({ inApp: true, ...state }, '', url)
  window.dispatchEvent(new Event('batches:navigate'))
  if (!replace && !state.keepScroll) window.scrollTo(0, 0)
}

/** Back within the viewer if we came from somewhere in it, else to `fallback`. */
export function back(fallback = '/app') {
  if (window.history.state?.inApp) window.history.back()
  else go(fallback, { replace: true })
}

export function Link({ to, children, ...rest }) {
  return (
    <a href={to} {...rest} onClick={(e) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
      e.preventDefault()
      rest.onNavigate?.()
      go(to)
    }}>{children}</a>
  )
}

export const batchURL = (id, photoID) => `/b/${id}${photoID ? `?photo=${photoID}` : ''}`
/** The app's own link scheme, for the "Open in Batches" button. Only well-formed ids go in. */
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const appURL = (id, photoID) => uuid.test(id ?? '')
  ? `strewn://pile/${id.toLowerCase()}${uuid.test(photoID ?? '') ? `?photo=${photoID.toLowerCase()}` : ''}`
  : 'strewn://'

// Photos -----------------------------------------------------------------------------------------

/**
 * One photo at its true shape, known before any bytes arrive, and never cropped. `tier` forces a
 * copy; otherwise the copy is chosen from the size it's drawn at.
 */
export function Photo({ photo, tier, eager, className = '', style }) {
  const { ref, src, state } = usePhotoSource(photo, { tier, eager })
  return (
    <div ref={ref} className={`photo ${state} ${className}`}
         style={{ aspectRatio: `${photo.pixel_width || 1} / ${photo.pixel_height || 1}`, ...style }}>
      {src && <img src={src} alt={photo.caption ?? ''} draggable={false} />}
      {state === 'failed' && <span className="noimg" title="This photo couldn't be loaded">Couldn't load</span>}
    </div>
  )
}

/**
 * A photo in its batch's frame. The frame only adds space around the photo; it never changes the
 * photo's shape. `photoWidth` sets the photo's width (CSS length); otherwise it fills the frame.
 */
export function Framed({ photo, frame, font, index = 0, photoWidth, tier, onClick, className = '' }) {
  const [t, r, b, l] = insets(frame)
  return (
    <div className={`frame frame-${frame.kind} ${onClick ? 'tappable' : ''} ${className}`}
         style={{ padding: `${t}px ${r}px ${b}px ${l}px`, width: photoWidth ? 'fit-content' : undefined }}
         onClick={onClick} role={onClick ? 'button' : undefined} tabIndex={onClick ? 0 : undefined}
         aria-label={onClick ? `View photo ${index + 1}${photo.caption ? `, ${photo.caption}` : ''}` : undefined}
         onKeyDown={onClick ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick() } } : undefined}>
      {frame.kind === 'galleryMat' ? (
        <div className="mat-inner"><Photo photo={photo} tier={tier} style={photoWidth ? { width: photoWidth } : undefined} /></div>
      ) : (
        <Photo photo={photo} tier={tier} style={photoWidth ? { width: photoWidth } : undefined} />
      )}
      {frame.kind === 'polaroid' && photo.caption && (
        <span className="handwritten" style={{ height: b, left: l, right: r, fontFamily: captionFamily(font),
          fontSize: font ? 15 : Math.max(15, Math.min(26, (frame.borderWidth ?? 14) * 1.5)) }}>{photo.caption}</span>
      )}
      {frame.kind === 'filmStrip' && (
        <span className="edge"><span>BATCHES 400</span><span>▸ {String(index + 1).padStart(2, '0')}A</span></span>
      )}
    </div>
  )
}

/** The collapsed batch: up to five prints, cover on top, squared up unless tilted. */
export function Pile({ batch, tilted }) {
  const stack = pileStack(batch)
  const film = batch.frame.kind === 'filmStrip'
  return (
    <div className="pile">
      {stack.length === 0 && <div className="pile-empty">No photos yet</div>}
      {stack.map((photo, i) => {
        const p = pilePlacement(photo, i === stack.length - 1, tilted)
        return (
          <div key={photo.id} className={`print ${film ? 'print-film' : ''}`} style={{
            width: `${p.width * 100}%`, zIndex: i,
            transform: `translate(-50%, -50%) translate(${p.x * 100}cqw, ${p.y * 100}cqw) rotate(${p.angle}deg)`,
          }}>
            <Photo photo={photo} />
          </div>
        )
      })}
    </div>
  )
}

// People -----------------------------------------------------------------------------------------

const hues = [8, 28, 50, 120, 172, 216, 270]
export function Avatar({ user, size = 32 }) {
  const [broken, setBroken] = useState(false)
  const h = hues[hash(user?.id ?? '') % hues.length]
  const url = user?.avatar_url
  if (url && /^https:\/\//.test(url) && !broken) {
    return <img className="avatar" src={url} alt="" width={size} height={size} onError={() => setBroken(true)} />
  }
  return (
    <span className="avatar" aria-hidden="true" style={{
      width: size, height: size, fontSize: size * 0.42,
      background: `linear-gradient(135deg, hsl(${h} 42% 44%), hsl(${h + 28} 52% 60%))`,
    }}>{user?.display_name?.trim()?.[0]?.toUpperCase() ?? '·'}</span>
  )
}

// Icons ------------------------------------------------------------------------------------------
// Drawn here so they follow the text colour and need nothing from the network.

const paths = {
  back: <path d="M15 5l-7 7 7 7" />,
  close: <path d="M6 6l12 12M18 6L6 18" />,
  heart: <path d="M12 20s-7-4.4-7-10a4 4 0 017-2.6A4 4 0 0119 10c0 5.6-7 10-7 10z" />,
  comment: <path d="M5 6.5A2.5 2.5 0 017.5 4h9A2.5 2.5 0 0119 6.5v7a2.5 2.5 0 01-2.5 2.5H11l-4 3.5V16h0a2.5 2.5 0 01-2-2.5z" />,
  more: <g><circle cx="6" cy="12" r="1.3" /><circle cx="12" cy="12" r="1.3" /><circle cx="18" cy="12" r="1.3" /></g>,
  flag: <path d="M6 20V4m0 1h10l-2 3.5L16 12H6" />,
  trash: <path d="M5 7h14M10 7V5h4v2m-7 0l1 12h8l1-12" />,
  link: <path d="M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1M14 10a4 4 0 00-5.7 0l-3 3a4 4 0 005.7 5.7l1-1" />,
  star: <path d="M12 4l2.4 5 5.4.6-4 3.7 1.1 5.4L12 16l-4.9 2.7 1.1-5.4-4-3.7 5.4-.6z" />,
  phone: <path d="M8 3h8a1 1 0 011 1v16a1 1 0 01-1 1H8a1 1 0 01-1-1V4a1 1 0 011-1zm3 15h2" />,
  send: <path d="M12 19V5m-6 6l6-6 6 6" />,
  forward: <path d="M9 5l7 7-7 7" />,
  up: <path d="M6 15l6-6 6 6" />,
  down: <path d="M6 9l6 6 6-6" />,
  plus: <path d="M12 5v14M5 12h14" />,
  undo: <path d="M9 7L5 11l4 4M5 11h9a5 5 0 010 10h-2" />,
  redo: <path d="M15 7l4 4-4 4M19 11h-9a5 5 0 000 10h2" />,
  book: <path d="M5 4.5A1.5 1.5 0 016.5 3H19v15H6.5A1.5 1.5 0 005 19.5zM5 19.5A1.5 1.5 0 006.5 21H19" />,
  eye: <g><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" /><circle cx="12" cy="12" r="2.8" /></g>,
  eyeOff: <g><path d="M3 3l18 18M10.6 10.6a2.8 2.8 0 004 4" /><path d="M9.4 5.8A9.8 9.8 0 0112 5.5C18 5.5 21.5 12 21.5 12a16.8 16.8 0 01-3.2 4.1M6.4 6.7C4.1 8.4 2.5 12 2.5 12s3.5 6.5 9.5 6.5c1.7 0 3.2-.4 4.5-1.1" /></g>,
  tag: <g><path d="M20.6 13.4l-7.2 7.2a2 2 0 01-2.8 0L3.5 13.5V4h9.5l7.6 7.6a2 2 0 010 2.8z" /><circle cx="8" cy="8" r="1.4" /></g>,
  bell: <g><path d="M18 8a6 6 0 10-12 0c0 7-3 8.5-3 8.5h18S18 15 18 8z" /><path d="M13.7 20a2 2 0 01-3.4 0" /></g>,
  upload: <path d="M12 16V4m-5 5l5-5 5 5M4 17v2a1 1 0 001 1h14a1 1 0 001-1v-2" />,
  photo: <g><rect x="3.5" y="4.5" width="17" height="15" rx="2.2" /><circle cx="8.8" cy="9.5" r="1.4" /><path d="M4.5 17.5l5-4.8 3.5 3.3 2.8-2.6 3.7 4.1" /></g>,
  share: <g><path d="M12 15V4m-4.5 4.5L12 4l4.5 4.5" /><path d="M5 13v5.5A1.5 1.5 0 006.5 20h11a1.5 1.5 0 001.5-1.5V13" /></g>,
  lock: <g><rect x="5" y="11" width="14" height="9.5" rx="2" /><path d="M8 11V7.8a4 4 0 018 0V11" /></g>,
  users: <g><circle cx="9.5" cy="8.5" r="3.2" /><path d="M3.5 19c.6-3.1 3-5 6-5s5.4 1.9 6 5" /><circle cx="16.8" cy="9.3" r="2.4" /><path d="M16.5 14.3c2.1.4 3.6 1.9 4 4.2" /></g>,
  globe: <g><circle cx="12" cy="12" r="8.5" /><path d="M3.6 12h16.8M12 3.5c2.5 2.4 3.8 5.4 3.8 8.5s-1.3 6.1-3.8 8.5c-2.5-2.4-3.8-5.4-3.8-8.5S9.5 5.9 12 3.5z" /></g>,
  frame: <g><rect x="3.5" y="3.5" width="17" height="17" rx="2" /><rect x="7" y="7" width="10" height="10" rx="1" /></g>,
  edit: <path d="M15.5 4.5l4 4L8 20H4v-4L15.5 4.5z" />,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
}
export function Icon({ name, filled, size = 20, label }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill={filled ? 'currentColor' : 'none'}
         stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round"
         role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true}>
      {paths[name]}
    </svg>
  )
}

// Small pieces -----------------------------------------------------------------------------------

export function Spinner() {
  return <div className="center" role="status" aria-label="Loading"><div className="spinner" /></div>
}

/** A menu of actions behind a round button. Closes on outside click and Escape. */
export function Menu({ label = 'More', items, className = '' }) {
  const [open, setOpen] = useState(false)
  useEffect(() => {
    if (!open) return
    const close = () => setOpen(false)
    const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false) } }
    window.addEventListener('click', close)
    window.addEventListener('keydown', key, true)
    return () => { window.removeEventListener('click', close); window.removeEventListener('keydown', key, true) }
  }, [open])
  const shown = items.filter(Boolean)
  if (!shown.length) return null
  return (
    <div className={`menu ${className}`}>
      <button className="round" aria-label={label} aria-haspopup="menu" aria-expanded={open}
              onClick={(e) => { e.stopPropagation(); setOpen(!open) }}><Icon name="more" /></button>
      {open && (
        <div className="menu-list" role="menu">
          {shown.map((item) => (
            <button key={item.label} role="menuitem" className={item.destructive ? 'destructive' : ''}
                    onClick={(e) => { e.stopPropagation(); setOpen(false); item.onClick() }}>
              {item.icon && <Icon name={item.icon} size={18} />}{item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

export function Sheet({ title, onClose, children, className = '' }) {
  useEffect(() => {
    const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose() } }
    window.addEventListener('keydown', key, true)
    return () => window.removeEventListener('keydown', key, true)
  }, [onClose])
  return (
    <div className="sheet-bg" onClick={onClose}>
      <div className={`sheet ${className}`} role="dialog" aria-modal="true" aria-label={title} onClick={(e) => e.stopPropagation()}>
        <div className="sheet-head">
          <h2 className="title">{title}</h2>
          <button className="round" onClick={onClose} aria-label="Close"><Icon name="close" size={18} /></button>
        </div>
        {children}
      </div>
    </div>
  )
}

export function Toast({ text, onDone }) {
  useEffect(() => { const t = setTimeout(onDone, 2400); return () => clearTimeout(t) }, [text, onDone])
  return <div className="toast" role="status">{text}</div>
}

export function hash(s) {
  let h = 2166136261
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619)
  h ^= h >>> 16; h = Math.imul(h, 0x85ebca6b); h ^= h >>> 13; h = Math.imul(h, 0xc2b2ae35); h ^= h >>> 16
  return h >>> 0
}

export const counted = (n, noun, plural) => `${n} ${n === 1 ? noun : plural ?? noun + 's'}`
export const shortDate = (d) => new Date(d).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
export const longDate = (d) => new Date(d).toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })
export function relative(d) {
  const minutes = Math.round((Date.now() - new Date(d)) / 60000)
  if (minutes < 1) return 'now'
  if (minutes < 60) return `${minutes}m`
  if (minutes < 60 * 24) return `${Math.round(minutes / 60)}h`
  const days = Math.round(minutes / 1440)
  return days < 7 ? `${days}d` : shortDate(d)
}

/** Splits text around valid @handle mentions into plain strings and { handle, display } tokens. */
export function splitMentions(text) {
  if (!text) return []
  const parts = []
  const pushStr = (s) => {
    if (!s) return
    if (typeof parts[parts.length - 1] === 'string') parts[parts.length - 1] += s
    else parts.push(s)
  }
  const re = /(^|[^a-zA-Z0-9_.])@([a-zA-Z0-9_.]{3,24})/g
  let last = 0
  let m
  while ((m = re.exec(text)) !== null) {
    const prefix = m[1]
    const raw = m[2]
    const clean = raw.replace(/\.+$/, '')
    const trailing = raw.slice(clean.length)
    if (m.index > last) pushStr(text.slice(last, m.index))
    if (prefix) pushStr(prefix)
    if (/^[a-z0-9_.]{3,24}$/i.test(clean)) {
      parts.push({ handle: clean.toLowerCase(), display: `@${clean}` })
      if (trailing) pushStr(trailing)
    } else {
      pushStr(`@${raw}`)
    }
    last = m.index + m[0].length
  }
  if (last < text.length) pushStr(text.slice(last))
  return parts
}

/** Splits text around valid @handle mentions and links them to /app/u/<handle>. */
export function MentionText({ text }) {
  const parts = splitMentions(text)
  if (!parts.length) return null
  return (
    <>
      {parts.map((part, i) => typeof part === 'string'
        ? part
        : <Link key={i} className="mention" to={`/app/u/${part.handle}`}>{part.display}</Link>)}
    </>
  )
}

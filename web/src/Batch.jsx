import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import * as api from './api.js'
import { backdrop, boardLayout, cover, fontFamily, insets, showsBoard } from './look.js'
import {
  Avatar, Framed, Icon, Link, Menu, Photo, Sheet, Spinner, Toast,
  appURL, back, batchURL, counted, go, longDate, relative,
} from './ui.jsx'

/**
 * A batch spread out, as GalleryView draws it in the app: its title page, then its photos as a
 * column, two columns, a roll of film, or the owner's freehand board, on the owner's background.
 * Full frame is the rule; nothing is cropped.
 */
export default function BatchPage({ id, photoID, ctx }) {
  const { me } = ctx
  const [batch, setBatch] = useState(undefined)   // undefined while loading, null when not allowed
  const [problem, setProblem] = useState(null)
  const [reactions, setReactions] = useState(null)
  const [reporting, setReporting] = useState(null)
  const [toast, setToast] = useState(null)

  useEffect(() => {
    let live = true
    setBatch(undefined); setProblem(null); setReactions(null)
    api.batch(id).then((b) => {
      if (!live) return
      // Someone you've blocked is hidden by the database already; this covers the moment between.
      setBatch(b && !ctx.blocked.has(b.owner_id) ? b : null)
    }).catch((e) => live && setProblem(e))
    return () => { live = false }
  }, [id, ctx.blocked])

  const photoIDs = useMemo(() => batch?.photos.map((p) => p.id) ?? [], [batch])
  useEffect(() => {
    if (!photoIDs.length) return
    api.reactions(photoIDs, me.id).then(setReactions).catch(() => setReactions(null))
  }, [photoIDs, me.id])

  /** Optimistic: the heart fills straight away and goes back if the server says no. */
  const like = useCallback((photo) => {
    const before = reactions?.[photo.id]
    if (!before) return
    const after = { ...before, liked: !before.liked, likes: Math.max(0, before.likes + (before.liked ? -1 : 1)) }
    setReactions((r) => ({ ...r, [photo.id]: after }))
    api.setLiked(after.liked, photo.id, me.id).catch(() => {
      setReactions((r) => ({ ...r, [photo.id]: before }))
      setToast("Couldn't save that like")
    })
  }, [reactions, me.id])

  const setCommentCount = useCallback((photoID, n) => {
    setReactions((r) => (r?.[photoID] ? { ...r, [photoID]: { ...r[photoID], comments: n } } : r))
  }, [])

  if (problem) return <Trouble text={problem.message} />
  if (batch === undefined) return <Spinner />
  if (batch === null) return <NoAccess id={id} photoID={photoID} me={me} />

  const isOwner = batch.owner_id === me.id
  const look = backdrop(batch)
  const viewing = photoID ? batch.photos.find((p) => p.id === photoID) : null
  const open = (photo) => go(batchURL(batch.id, photo.id), { state: { viewer: true, keepScroll: true } })
  const closeViewer = () => {
    if (window.history.state?.viewer) window.history.back()
    else go(batchURL(batch.id), { replace: true, state: { keepScroll: true } })
  }
  const copyLink = async (photo) => {
    try {
      await navigator.clipboard.writeText(`${window.location.origin}${batchURL(batch.id, photo?.id)}`)
      setToast('Link copied. It opens for people who can see this batch.')
    } catch { setToast("Couldn't copy the link") }
  }
  const canReport = (photo) => (photo.added_by ?? batch.owner_id) !== me.id

  return (
    <div className={`wall wall-${look.key} ${look.neutral ? 'neutral' : ''}`}
         data-scheme={look.scheme ?? undefined}
         style={look.color ? { '--wall': look.color } : undefined}>
      <BatchHeader batch={batch} isOwner={isOwner} onCopy={() => copyLink(null)}
                   onReport={!isOwner ? () => setReporting({ subject: 'this batch', batchID: batch.id, userID: batch.owner_id }) : null} />
      <section className="intro">
        <h1 className="batch-title" style={{ fontFamily: fontFamily(batch.font) }}>{batch.title}</h1>
        {batch.description && <p className="description" style={{ fontFamily: fontFamily(batch.font) }}>{batch.description}</p>}
        <p className="meta">{[batch.shot_on && longDate(batch.shot_on), batch.place, counted(batch.photos.length, 'frame')].filter(Boolean).join(' · ')}</p>
        {!isOwner && batch.owner && (
          <Link className="byline" to={`/app/u/${batch.owner.handle}`}>
            <Avatar user={batch.owner} size={24} /><b>{batch.owner.display_name}</b><span className="chev">›</span>
          </Link>
        )}
      </section>
      <BatchBody batch={batch} reactions={reactions} onOpen={open} />
      {!batch.photos.length && <p className="meta center-text">No photos in this batch yet.</p>}
      <p className="app-only meta center-text">Editing, adding photos and arranging happen in Batches on iPhone.</p>
      {viewing && (
        <Viewer batch={batch} photo={viewing} me={me} isOwner={isOwner} reactions={reactions?.[viewing.id]}
                onClose={closeViewer} onLike={() => like(viewing)} onCopy={() => copyLink(viewing)}
                onCommentCount={(n) => setCommentCount(viewing.id, n)}
                onReport={canReport(viewing) ? () => setReporting({ subject: 'this photo', photoID: viewing.id }) : null}
                onReportComment={(c) => setReporting({ subject: 'this comment', commentID: c.id })} />
      )}
      {reporting && <ReportSheet target={reporting} onClose={() => setReporting(null)} onSent={() => { setReporting(null); setToast('Thanks. We look at every report within a day.') }} />}
      {toast && <Toast text={toast} onDone={() => setToast(null)} />}
    </div>
  )
}

function BatchHeader({ batch, isOwner, onCopy, onReport }) {
  const [scrolled, setScrolled] = useState(false)
  useEffect(() => {
    const on = () => setScrolled(window.scrollY > 140)
    on()
    window.addEventListener('scroll', on, { passive: true })
    return () => window.removeEventListener('scroll', on)
  }, [])
  return (
    <header className="gallerybar">
      <button className="round" onClick={() => back('/app')} aria-label="Back"><Icon name="back" /></button>
      <div className={`gallerybar-title ${scrolled ? 'on' : ''}`} aria-hidden={!scrolled}>
        <b style={{ fontFamily: fontFamily(batch.font) }}>{batch.title}</b>
        <span className="meta">{counted(batch.photos.length, 'frame')}{!isOwner && batch.owner ? ` · @${batch.owner.handle}` : ''}</span>
      </div>
      <a className="round" href={appURL(batch.id)} aria-label="Open in Batches" title="Open in Batches"><Icon name="phone" /></a>
      <Menu items={[
        { label: 'Copy link', icon: 'link', onClick: onCopy },
        onReport && { label: 'Report batch', icon: 'flag', onClick: onReport },
      ]} />
    </header>
  )
}

function BatchBody({ batch, reactions, onOpen }) {
  const { frame } = batch
  if (frame.kind === 'filmStrip') return <FilmRoll batch={batch} reactions={reactions} onOpen={onOpen} />
  if (showsBoard(batch)) return <Board batch={batch} onOpen={onOpen} />
  if (frame.layout === 'twoColumn') {
    // A contact sheet: the prints alone read better, as in the app.
    return (
      <div className="masonry">
        {batch.photos.map((photo, i) => (
          <div key={photo.id} className="masonry-item">
            <Framed photo={photo} frame={frame} font={batch.font} index={i} onClick={() => onOpen(photo)} />
          </div>
        ))}
      </div>
    )
  }
  const [t, r, b, l] = insets(frame)
  return (
    <div className="column">
      {batch.photos.map((photo, i) => {
        const aspect = (photo.pixel_width || 1) / (photo.pixel_height || 1)
        // The whole framed print fits in the window: tall portraits are shown whole.
        const width = `min(calc(100cqw - ${l + r}px), calc((100svh - ${150 + t + b}px) * ${aspect}))`
        return (
          <figure key={photo.id}>
            <Framed photo={photo} frame={frame} font={batch.font} index={i} photoWidth={width} onClick={() => onOpen(photo)} />
            <MetaRow batch={batch} photo={photo} index={i} reactions={reactions?.[photo.id]} />
          </figure>
        )
      })}
    </div>
  )
}

function MetaRow({ batch, photo, index, reactions }) {
  const parts = [String(index + 1).padStart(2, '0')]
  if (photo.exif?.aperture) parts.push(`ƒ${+photo.exif.aperture.toFixed(1)}`)
  if (photo.exif?.shutter) parts.push(photo.exif.shutter)
  if (photo.exif?.iso) parts.push(`ISO ${photo.exif.iso}`)
  if (photo.edit) parts.push('edited')
  return (
    <figcaption className="metarow">
      <span className="meta">{parts.join(' · ')}{photo.adder ? ` · added by @${photo.adder.handle}` : ''}</span>
      <span className="spacer" />
      {reactions && <ReactionsLine r={reactions} />}
      {photo.id === cover(batch)?.id && <span className="cover-tag"><Icon name="star" filled size={12} /> Cover</span>}
    </figcaption>
  )
}

function ReactionsLine({ r }) {
  if (!r.likes && !r.comments) return null
  return (
    <span className="reactions-line" aria-label={`${counted(r.likes, 'like')}, ${counted(r.comments, 'comment')}`}>
      {r.likes > 0 && <span className={r.liked ? 'liked' : ''}><Icon name="heart" filled={r.liked} size={13} />{r.likes}</span>}
      {r.comments > 0 && <span><Icon name="comment" size={13} />{r.comments}</span>}
    </span>
  )
}

/** One continuous strip of film running down the page, perforations along both sides. */
function FilmRoll({ batch, reactions, onOpen }) {
  const border = batch.frame.borderWidth ?? 14
  const band = border * 1.1 + 22
  return (
    <div className="roll" style={{ '--band': `${band}px`, '--hole': `${Math.max(7, border * 0.55)}px`, gap: Math.max(14, border * 0.8) }}>
      {batch.photos.map((photo, i) => {
        const aspect = (photo.pixel_width || 1) / (photo.pixel_height || 1)
        return (
          <figure key={photo.id}>
            <button className="roll-frame" onClick={() => onOpen(photo)} aria-label={`View photo ${i + 1}`}>
              <Photo photo={photo} style={{ width: `min(100%, calc((100svh - 210px) * ${aspect}))` }} />
            </button>
            <MetaRow batch={batch} photo={photo} index={i} reactions={reactions?.[photo.id]} />
          </figure>
        )
      })}
    </div>
  )
}

/** The owner's freehand board: prints where they put them, at their size and turn. */
function Board({ batch, onOpen }) {
  const ref = useRef(null)
  const [width, setWidth] = useState(0)
  useEffect(() => {
    const ro = new ResizeObserver(([e]) => setWidth(Math.round(e.contentRect.width)))
    ro.observe(ref.current)
    return () => ro.disconnect()
  }, [])
  const layout = useMemo(() => (width ? boardLayout(batch, width) : null), [batch, width])
  return (
    <div className="board" ref={ref} style={{ height: layout?.height ?? 300 }}>
      {layout?.items.map(({ photo, index, place, imageWidth }) => (
        <div key={photo.id} className="board-item" style={{
          left: place.x * width, top: place.y * width, zIndex: place.z,
          transform: `translate(-50%, -50%) rotate(${place.rotation}deg)`,
        }}>
          <Framed photo={photo} frame={batch.frame} font={batch.font} index={index}
                  photoWidth={`${imageWidth}px`} onClick={() => onOpen(photo)} />
        </div>
      ))}
    </div>
  )
}

// The full-frame viewer --------------------------------------------------------------------------

/** Just the photo you opened, as large as it fits and never cropped, with its likes and comments. */
function Viewer({ batch, photo, me, isOwner, reactions, onClose, onLike, onCopy, onReport, onReportComment, onCommentCount }) {
  const [commentsOpen, setCommentsOpen] = useState(() => window.matchMedia('(min-width: 960px)').matches)
  const [wide, setWide] = useState(() => window.matchMedia('(min-width: 960px)').matches)
  useEffect(() => {
    const mq = window.matchMedia('(min-width: 960px)')
    const on = () => setWide(mq.matches)
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [])
  useEffect(() => {
    const key = (e) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', key)
    document.body.classList.add('locked')
    return () => { window.removeEventListener('keydown', key); document.body.classList.remove('locked') }
  }, [onClose])
  const index = batch.photos.indexOf(photo)
  const aspect = (photo.pixel_width || 1) / (photo.pixel_height || 1)

  return (
    <div className={`viewer ${commentsOpen && wide ? 'with-panel' : ''}`} role="dialog" aria-modal="true" aria-label={`Photo ${index + 1} of ${batch.title}`}>
      <div className="viewer-main" onClick={onClose}>
        <div className="viewer-top" onClick={(e) => e.stopPropagation()}>
          <button className="round dark" onClick={onClose} aria-label="Close"><Icon name="close" /></button>
          <span className="viewer-count">{String(index + 1).padStart(2, '0')} of {batch.photos.length}</span>
          <Menu className="dark" items={[
            { label: 'Copy link to photo', icon: 'link', onClick: onCopy },
            onReport && { label: 'Report photo', icon: 'flag', onClick: onReport },
          ]} />
        </div>
        <div className="viewer-photo" onClick={(e) => e.stopPropagation()}
             style={{ '--aspect': aspect, aspectRatio: `${photo.pixel_width || 1} / ${photo.pixel_height || 1}` }}>
          <Photo photo={photo} tier="m" eager className="under" />
          <Photo photo={photo} tier="l" eager />
        </div>
        <div className="viewer-bottom" onClick={(e) => e.stopPropagation()}>
          <div className="viewer-text">
            {photo.caption && <p className="caption">{photo.caption}</p>}
            <p className="meta light">{photo.adder ? `Added by @${photo.adder.handle} · ` : ''}{photo.pixel_width} × {photo.pixel_height} · full frame</p>
          </div>
          {reactions && (
            <div className="viewer-actions">
              <button className={`pill ${reactions.liked ? 'liked' : ''}`} onClick={onLike} aria-pressed={reactions.liked}
                      aria-label={reactions.liked ? 'Unlike' : 'Like'}>
                <Icon name="heart" filled={reactions.liked} /><span>{reactions.likes || ''}</span>
              </button>
              <button className={`pill ${commentsOpen ? 'on' : ''}`} onClick={() => setCommentsOpen(!commentsOpen)}
                      aria-expanded={commentsOpen} aria-label="Comments">
                <Icon name="comment" /><span>{reactions.comments || ''}</span>
              </button>
            </div>
          )}
        </div>
      </div>
      {commentsOpen && reactions && (
        <Comments photo={photo} batch={batch} me={me} isOwner={isOwner} panel={wide}
                  onClose={() => setCommentsOpen(false)} onCount={onCommentCount} onReport={onReportComment} />
      )}
    </div>
  )
}

/**
 * Comments on one photo. They can't be edited; their author and the batch's owner can remove them,
 * and anyone else who sees them can report them.
 */
function Comments({ photo, batch, me, isOwner, panel, onClose, onCount, onReport }) {
  const [list, setList] = useState(null)
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')
  const [confirming, setConfirming] = useState(null)
  const end = useRef(null)

  const load = useCallback(async () => {
    try {
      const rows = await api.comments(photo.id)
      setList(rows)
      onCount(rows.length)
    } catch (e) { setProblem(e.message); setList([]) }
  }, [photo.id]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setList(null); load() }, [load])
  useEffect(() => { end.current?.scrollIntoView({ block: 'end' }) }, [list?.length])

  const post = async (e) => {
    e.preventDefault()
    const body = draft.trim()
    if (!body || busy) return
    setBusy(true); setProblem('')
    try {
      await api.addComment(photo.id, body.slice(0, api.commentLimit), me.id)
      setDraft('')
      await load()
    } catch (err) { setProblem(err.message) } finally { setBusy(false) }
  }
  const remove = async (c) => {
    setConfirming(null)
    try { await api.deleteComment(c.id); await load() } catch (err) { setProblem(err.message) }
  }

  const body = (
    <>
      <div className="comments-list">
        {list === null && <div className="spinner small" />}
        {list?.length === 0 && <p className="meta empty-note">No comments yet. Say something about this one.</p>}
        {list?.map((c) => {
          const mine = c.author_id === me.id
          return (
            <div key={c.id} className="comment">
              <Avatar user={c.author} size={30} />
              <div className="comment-body">
                <p className="comment-head">
                  {c.author ? <Link to={`/app/u/${c.author.handle}`}><b>{c.author.display_name}</b></Link> : <b>Someone</b>}
                  <span className="meta">{relative(c.created_at)}</span>
                </p>
                <p className="comment-text">{c.body}</p>
              </div>
              <Menu label="Comment actions" items={[
                (mine || isOwner) && { label: 'Delete', icon: 'trash', destructive: true, onClick: () => setConfirming(c) },
                !mine && { label: 'Report', icon: 'flag', onClick: () => onReport(c) },
              ]} />
            </div>
          )
        })}
        <div ref={end} />
      </div>
      {problem && <p className="problem">{problem}</p>}
      <form className="composer" onSubmit={post}>
        <textarea rows={1} placeholder="Add a comment" value={draft} maxLength={api.commentLimit} aria-label="Comment"
                  onChange={(e) => setDraft(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) post(e) }} />
        <button className="round accent" disabled={!draft.trim() || busy} aria-label="Post comment"><Icon name="send" /></button>
      </form>
      {draft.length > api.commentLimit - 60 && <p className="meta counter">{api.commentLimit - draft.length} left</p>}
      {confirming && (
        <Sheet title="Delete this comment?" onClose={() => setConfirming(null)} className="small">
          <p className="sheet-text">{confirming.author_id === me.id ? 'It goes for everyone.' : `It goes for everyone, ${confirming.author?.display_name ?? 'its author'} included.`}</p>
          <div className="actions">
            <button className="secondary" onClick={() => setConfirming(null)}>Cancel</button>
            <button className="danger" onClick={() => remove(confirming)}>Delete</button>
          </div>
        </Sheet>
      )}
    </>
  )

  if (panel) {
    return (
      <aside className="comments-panel" aria-label="Comments">
        <div className="sheet-head"><h2 className="title">Comments</h2>
          <button className="round" onClick={onClose} aria-label="Close comments"><Icon name="close" size={18} /></button></div>
        {body}
      </aside>
    )
  }
  return <Sheet title="Comments" onClose={onClose} className="comments-sheet">{body}</Sheet>
}

function ReportSheet({ target, onClose, onSent }) {
  const [reason, setReason] = useState(null)
  const [details, setDetails] = useState('')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')
  const send = async () => {
    setBusy(true); setProblem('')
    try { await api.report({ ...target, reason, details }); onSent() } catch (e) { setProblem(e.message); setBusy(false) }
  }
  return (
    <Sheet title={`Report ${target.subject}`} onClose={onClose}>
      <p className="sheet-text">What's wrong with it? Reports are private; nobody is told who sent one.</p>
      <div className="options">
        {api.reportReasons.map((r) => (
          <label key={r.id} className={`option ${reason === r.id ? 'on' : ''}`}>
            <input type="radio" name="reason" checked={reason === r.id} onChange={() => setReason(r.id)} />
            <span>{r.title}</span>
          </label>
        ))}
      </div>
      <textarea placeholder="Anything else we should know (optional)" value={details} maxLength={1000}
                onChange={(e) => setDetails(e.target.value)} rows={3} />
      {problem && <p className="problem">{problem}</p>}
      <div className="actions">
        <button className="secondary" onClick={onClose}>Cancel</button>
        <button className="primary" disabled={!reason || busy} onClick={send}>Send report</button>
      </div>
    </Sheet>
  )
}

// When the batch can't be shown ------------------------------------------------------------------

/** Says nothing about the batch: a private one and one that doesn't exist look the same. */
function NoAccess({ id, photoID, me }) {
  return (
    <main className="notice">
      <div className="card notice-card">
        <h1 className="title">You don't have access to this batch</h1>
        <p>It's private, shared only with certain people, or it was deleted. If someone sent you the link, ask them to share the batch with <b>@{me.handle}</b>.</p>
        <div className="stacked">
          <Link className="button primary" to="/app">Go to your desk</Link>
          <a className="button secondary" href={appURL(id, photoID)}>Open in Batches</a>
          <button className="link" onClick={() => api.signOut()}>Sign in with a different email</button>
        </div>
      </div>
    </main>
  )
}

function Trouble({ text }) {
  return (
    <main className="notice">
      <div className="card notice-card">
        <h1 className="title">Something went wrong</h1>
        <p className="problem">{text}</p>
        <button className="primary" onClick={() => window.location.reload()}>Try again</button>
      </div>
    </main>
  )
}

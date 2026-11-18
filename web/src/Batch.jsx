import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import * as api from './api.js'
import { backdrop, boardLayout, cover, fontFamily, insets, showsBoard } from './look.js'
import { AddPhotosSheet, BatchLookSheet, ShareBatchSheet } from './UploadSheet.jsx'
import {
  Avatar, Framed, Icon, Link, MentionText, Menu, Photo, Sheet, Spinner, Toast,
  appURL, back, batchURL, counted, go, longDate, relative,
} from './ui.jsx'

const visibilityLabels = { private: 'Only me', people: 'Shared', followers: 'Followers', public: 'Public' }
const visibilityIcons = { private: 'lock', people: 'users', followers: 'users', public: 'globe' }

/**
 * A batch spread out, as GalleryView draws it in the app: its title page, then its photos as a
 * column, two columns, a roll of film, or the owner's freehand board, on the owner's background.
 * Full frame is the rule; nothing is cropped.
 */
export default function BatchPage({ id, photoID, ctx, signInInstead = null }) {
  const { me } = ctx
  const [batch, setBatch] = useState(undefined)   // undefined while loading, null when not allowed
  const [problem, setProblem] = useState(null)
  const [reactions, setReactions] = useState(null)
  const [canAdd, setCanAdd] = useState(false)
  const [tagging, setTagging] = useState(null)
  const [reporting, setReporting] = useState(null)
  const [addingOpen, setAddingOpen] = useState(false)
  const [sharingOpen, setSharingOpen] = useState(false)
  const [lookOpen, setLookOpen] = useState(false)
  const [confirmRemovePhoto, setConfirmRemovePhoto] = useState(null)
  const [confirmDeleteBatch, setConfirmDeleteBatch] = useState(false)
  const [busyAction, setBusyAction] = useState(false)
  const [toast, setToast] = useState(null)

  const refreshBatch = useCallback(async () => {
    const b = await api.batch(id)
    const visible = b && !ctx.blocked.has(b.owner_id) ? b : null
    setBatch(visible)
    return visible
  }, [id, ctx.blocked])

  useEffect(() => {
    let live = true
    setBatch(undefined); setProblem(null); setReactions(null); setCanAdd(false)
    api.batch(id).then(async (b) => {
      if (!live) return
      // Someone you've blocked is hidden by the database already; this covers the moment between.
      const visible = b && !ctx.blocked.has(b.owner_id) ? b : null
      setBatch(visible)
      if (visible && me && visible.owner_id !== me.id) {
        api.canAddToBatch(visible.id, me.id).then((allowed) => live && setCanAdd(allowed)).catch(() => {})
      }
    }).catch((e) => live && setProblem(e))
    return () => { live = false }
  }, [id, ctx.blocked, me?.id])

  const photoIDs = useMemo(() => batch?.photos.map((p) => p.id) ?? [], [batch])
  useEffect(() => {
    // Signed out there are no likes, comments or tags to show: those stay behind signing in.
    if (!photoIDs.length || !me) return
    api.reactions(photoIDs, me.id).then(setReactions).catch(() => setReactions(null))
  }, [photoIDs, me?.id])

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
  }, [reactions, me?.id])

  const setCommentCount = useCallback((photoID, n) => {
    setReactions((r) => (r?.[photoID] ? { ...r, [photoID]: { ...r[photoID], comments: n } } : r))
  }, [])

  const setPhotoTags = useCallback((photoID, tags) => {
    setReactions((r) => (r?.[photoID] ? { ...r, [photoID]: { ...r[photoID], tags } } : r))
  }, [])

  if (problem) return <Trouble text={problem.message} />
  if (batch === undefined) return <Spinner />
  if (batch === null) return me ? <NoAccess id={id} photoID={photoID} me={me} /> : signInInstead

  const isOwner = !!me && batch.owner_id === me.id
  const canUpload = isOwner || canAdd
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
  const canReport = (photo) => !!me && (photo.added_by ?? batch.owner_id) !== me.id
  const canTag = (photo) => isOwner || (canAdd && photo.added_by === me.id)
  const canRemovePhoto = (photo) => isOwner || (!!me && photo.added_by === me.id)

  const makeCover = async (photo) => {
    if (!isOwner || batch.cover_photo_id === photo.id) return
    const prevCover = batch.cover_photo_id
    setBatch((b) => (b ? { ...b, cover_photo_id: photo.id } : b))
    try {
      await api.updateBatch(batch.id, { cover_photo_id: photo.id })
      setToast('Cover updated.')
    } catch {
      setBatch((b) => (b ? { ...b, cover_photo_id: prevCover } : b))
      setToast("Couldn't set that cover")
    }
  }

  const removePhotoNow = async () => {
    const target = confirmRemovePhoto
    if (!target || busyAction) return
    setBusyAction(true)
    try {
      await api.removePhotoFromBatch({ batch, photo: target, isOwner })
      setConfirmRemovePhoto(null)
      if (viewing?.id === target.id) closeViewer()
      await refreshBatch()
      setToast('Photo removed from batch.')
    } catch (err) {
      setToast(err?.message || "Couldn't remove that photo")
    } finally {
      setBusyAction(false)
    }
  }

  const deleteBatchNow = async () => {
    if (!isOwner || busyAction) return
    setBusyAction(true)
    try {
      await api.deleteBatch(batch.id)
      go('/app')
    } catch (err) {
      setConfirmDeleteBatch(false)
      setToast(err?.message || "Couldn't delete this batch")
      setBusyAction(false)
    }
  }

  return (
    <div className={`wall wall-${look.key} ${look.neutral ? 'neutral' : ''} ${canUpload ? 'has-dock' : ''}`}
         data-scheme={look.scheme ?? undefined}
         style={look.color ? { '--wall': look.color } : undefined}>
      <BatchHeader
        batch={batch}
        isOwner={isOwner}
        canUpload={canUpload}
        guest={!me}
        onCopy={() => copyLink(null)}
        onAdd={() => setAddingOpen(true)}
        onShare={() => setSharingOpen(true)}
        onLook={() => setLookOpen(true)}
        onDelete={() => setConfirmDeleteBatch(true)}
        onReport={me && !isOwner ? () => setReporting({ subject: 'this batch', batchID: batch.id, userID: batch.owner_id }) : null}
      />
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
      <BatchBody batch={batch} reactions={reactions} canTag={canTag} onOpen={open} onTag={(p) => setTagging(p)} />
      {!batch.photos.length && (
        <div className="center-text empty-batch">
          <p className="meta">No photos in this batch yet.</p>
          {canUpload && (
            <button className="primary" onClick={() => setAddingOpen(true)}>
              <Icon name="plus" size={18} /><span>Add photos</span>
            </button>
          )}
        </div>
      )}
      {me ? (
        isOwner && <p className="app-only meta center-text">RAW develop and freehand board arranging are in Batches on iPhone.</p>
      ) : (
        <div className="guest-cta">
          <p className="meta">Sign in to like, comment and see who's tagged.</p>
          <div className="guest-cta-actions">
            <button className="primary" onClick={ctx.signIn}>Sign in</button>
            <a className="button secondary" href={appURL(batch.id, photoID)}>Open in Batches</a>
          </div>
        </div>
      )}
      {canUpload && (
        <nav className="batch-dock" aria-label="Batch actions">
          <button type="button" className="primary dock-add" onClick={() => setAddingOpen(true)}>
            <Icon name="plus" size={18} /><span>Add photos</span>
          </button>
          {isOwner && (
            <>
              <button type="button" className="dock-btn" onClick={() => setLookOpen(true)}>
                <Icon name="frame" size={18} /><span>Look</span>
              </button>
              <button type="button" className="dock-btn" onClick={() => setSharingOpen(true)}>
                <Icon name="share" size={18} /><span>Share</span>
              </button>
            </>
          )}
        </nav>
      )}
      {viewing && (
        <Viewer batch={batch} photo={viewing} me={me} isOwner={isOwner} canTag={canTag(viewing)}
                reactions={reactions?.[viewing.id]}
                onClose={closeViewer} onStep={(p) => go(batchURL(batch.id, p.id), { replace: true, state: { viewer: true, keepScroll: true } })}
                onLike={() => like(viewing)} onCopy={() => copyLink(viewing)}
                onTag={() => setTagging(viewing)}
                onMakeCover={isOwner && viewing.id !== cover(batch)?.id ? () => makeCover(viewing) : null}
                onRemove={canRemovePhoto(viewing) ? () => setConfirmRemovePhoto(viewing) : null}
                onCommentCount={(n) => setCommentCount(viewing.id, n)}
                onReport={canReport(viewing) ? () => setReporting({ subject: 'this photo', photoID: viewing.id }) : null}
                onReportComment={(c) => setReporting({ subject: 'this comment', commentID: c.id })} />
      )}
      {addingOpen && me && (
        <AddPhotosSheet
          batch={batch}
          me={me}
          isOwner={isOwner}
          onClose={() => setAddingOpen(false)}
          onAdded={(updated, count) => {
            setAddingOpen(false)
            if (updated) setBatch(updated)
            else refreshBatch()
            setToast(`Added ${counted(count, 'photo')}.`)
          }}
        />
      )}
      {sharingOpen && isOwner && (
        <ShareBatchSheet
          batch={batch}
          me={me}
          blocked={ctx.blocked}
          onClose={() => setSharingOpen(false)}
          onCopyLink={() => copyLink(null)}
          onSaved={(nextVisibility) => {
            setSharingOpen(false)
            setBatch((b) => (b ? { ...b, visibility: nextVisibility } : b))
            setToast('Sharing updated.')
          }}
        />
      )}
      {lookOpen && isOwner && (
        <BatchLookSheet
          batch={batch}
          onClose={() => setLookOpen(false)}
          onSaved={async () => {
            setLookOpen(false)
            await refreshBatch()
            setToast('Batch updated.')
          }}
        />
      )}
      {confirmRemovePhoto && (
        <Sheet title="Remove this photo from the batch?" onClose={() => !busyAction && setConfirmRemovePhoto(null)} className="small">
          <p className="sheet-text">It leaves the batch for everyone who can see it.</p>
          <div className="actions">
            <button className="secondary" disabled={busyAction} onClick={() => setConfirmRemovePhoto(null)}>Cancel</button>
            <button className="danger" disabled={busyAction} onClick={removePhotoNow}>
              {busyAction ? 'Removing…' : 'Remove photo'}
            </button>
          </div>
        </Sheet>
      )}
      {confirmDeleteBatch && (
        <Sheet title={`Delete “${batch.title}”?`} onClose={() => !busyAction && setConfirmDeleteBatch(false)} className="small">
          <p className="sheet-text">This deletes the batch and its shared copies for everyone. This cannot be undone.</p>
          <div className="actions">
            <button className="secondary" disabled={busyAction} onClick={() => setConfirmDeleteBatch(false)}>Cancel</button>
            <button className="danger" disabled={busyAction} onClick={deleteBatchNow}>
              {busyAction ? 'Deleting…' : 'Delete batch'}
            </button>
          </div>
        </Sheet>
      )}
      {tagging && (
        <TagsSheet photo={tagging} me={me} blocked={ctx.blocked} canManage={canTag(tagging)}
                   tags={reactions?.[tagging.id]?.tags ?? []}
                   onClose={() => setTagging(null)}
                   onChange={(next) => setPhotoTags(tagging.id, next)} />
      )}
      {reporting && <ReportSheet target={reporting} onClose={() => setReporting(null)} onSent={() => { setReporting(null); setToast('Thanks. We look at every report within a day.') }} />}
      {toast && <Toast text={toast} onDone={() => setToast(null)} />}
    </div>
  )
}

function BatchHeader({ batch, isOwner, canUpload, guest, onCopy, onAdd, onShare, onLook, onDelete, onReport }) {
  const [scrolled, setScrolled] = useState(false)
  useEffect(() => {
    const on = () => setScrolled(window.scrollY > 140)
    on()
    window.addEventListener('scroll', on, { passive: true })
    return () => window.removeEventListener('scroll', on)
  }, [])
  const visIcon = visibilityIcons[batch.visibility] ?? 'lock'
  const visLabel = visibilityLabels[batch.visibility] ?? 'Only me'
  return (
    <header className="gallerybar">
      {guest ? (
        <a className="round brand-round" href="/" aria-label="Batches"><img src="/img/icon.png" alt="" width="26" height="26" /></a>
      ) : (
        <button className="round" onClick={() => back('/app')} aria-label="Back"><Icon name="back" /></button>
      )}
      <div className={`gallerybar-title ${scrolled ? 'on' : ''}`} aria-hidden={!scrolled}>
        <b style={{ fontFamily: fontFamily(batch.font) }}>{batch.title}</b>
        <span className="meta">{counted(batch.photos.length, 'frame')}{!isOwner && batch.owner ? ` · @${batch.owner.handle}` : ''}</span>
      </div>
      {isOwner && (
        <button type="button" className="audience-pill" onClick={onShare} aria-label={`Share, ${visLabel}`}>
          <Icon name={visIcon} size={15} /><span>{visLabel}</span>
        </button>
      )}
      <a className="round" href={appURL(batch.id)} aria-label="Open in Batches" title="Open in Batches"><Icon name="phone" /></a>
      <Menu items={[
        canUpload && { label: 'Add photos', icon: 'plus', onClick: onAdd },
        isOwner && { label: 'Look & details', icon: 'frame', onClick: onLook },
        isOwner && { label: 'Share batch', icon: 'share', onClick: onShare },
        { label: 'Copy link', icon: 'link', onClick: onCopy },
        isOwner && { label: 'Delete batch', icon: 'trash', destructive: true, onClick: onDelete },
        onReport && { label: 'Report batch', icon: 'flag', onClick: onReport },
      ]} />
    </header>
  )
}

function BatchBody({ batch, reactions, canTag, onOpen, onTag }) {
  const { frame } = batch
  if (frame.kind === 'filmStrip') return <FilmRoll batch={batch} reactions={reactions} canTag={canTag} onOpen={onOpen} onTag={onTag} />
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
            <MetaRow batch={batch} photo={photo} index={i} reactions={reactions?.[photo.id]}
                     canTag={canTag(photo)} onTag={() => onTag(photo)} />
          </figure>
        )
      })}
    </div>
  )
}

function MetaRow({ batch, photo, index, reactions, canTag, onTag }) {
  const parts = [String(index + 1).padStart(2, '0')]
  if (photo.exif?.aperture) parts.push(`ƒ${+photo.exif.aperture.toFixed(1)}`)
  if (photo.exif?.shutter) parts.push(photo.exif.shutter)
  if (photo.exif?.iso) parts.push(`ISO ${photo.exif.iso}`)
  if (photo.edit) parts.push('edited')
  const tags = reactions?.tags ?? []
  return (
    <figcaption className="metarow">
      <span className="meta">{parts.join(' · ')}{photo.adder ? ` · added by @${photo.adder.handle}` : ''}</span>
      {tags.length > 0 && (
        <button type="button" className="tag-chip" onClick={onTag}>
          <Icon name="tag" size={12} />
          <span>{tags[0].user ? `@${tags[0].user.handle}` : '1 tagged'}{tags.length > 1 ? ` +${tags.length - 1}` : ''}</span>
        </button>
      )}
      <span className="spacer" />
      {canTag && !tags.length && (
        <button type="button" className="tag-chip quiet" onClick={onTag} aria-label="Tag people">
          <Icon name="tag" size={12} /><span>Tag</span>
        </button>
      )}
      {reactions && <ReactionsLine r={reactions} />}
      {photo.id === cover(batch)?.id && <span className="cover-tag"><Icon name="star" filled size={12} /> Cover</span>}
    </figcaption>
  )
}

function ReactionsLine({ r }) {
  const tagCount = r.tags?.length ?? 0
  if (!r.likes && !r.comments && !tagCount) return null
  return (
    <span className="reactions-line" aria-label={`${counted(r.likes, 'like')}, ${counted(r.comments, 'comment')}`}>
      {r.likes > 0 && <span className={r.liked ? 'liked' : ''}><Icon name="heart" filled={r.liked} size={13} />{r.likes}</span>}
      {r.comments > 0 && <span><Icon name="comment" size={13} />{r.comments}</span>}
    </span>
  )
}

/** One continuous strip of film running down the page, perforations along both sides. */
function FilmRoll({ batch, reactions, canTag, onOpen, onTag }) {
  const border = batch.frame.borderWidth ?? 14
  const band = border * 1.1 + 22
  const ref = useRef(null)
  useFrameByFrame(ref)
  return (
    <div className="roll" ref={ref} style={{ '--band': `${band}px`, '--hole': `${Math.max(7, border * 0.55)}px`, gap: Math.max(14, border * 0.8) }}>
      {batch.photos.map((photo, i) => {
        // Every frame runs the full width of the strip, portraits included.
        return (
          <figure key={photo.id}>
            <button className="roll-frame" onClick={() => onOpen(photo)} aria-label={`View photo ${i + 1}`}>
              <Photo photo={photo} style={{ width: '100%' }} />
            </button>
            <MetaRow batch={batch} photo={photo} index={i} reactions={reactions?.[photo.id]}
                     canTag={canTag(photo)} onTag={() => onTag(photo)} />
          </figure>
        )
      })}
    </div>
  )
}

/**
 * On a laptop the roll advances a frame at a time, like winding film: one trackpad swipe, wheel
 * turn or arrow key glides to the next photo. A photo taller than the window stops twice, at its
 * top and then its bottom, so none of it is skipped. Touch screens keep their own scrolling.
 */
function useFrameByFrame(rollRef) {
  useEffect(() => {
    const bar = 64            // the sticky header
    let quietTimer = null, gesture = false, target = null, targetAt = 0
    let stepAt = 0, lastAt = 0, peak = 0, low = 0, dirNow = 0

    const stops = () => {
      const avail = window.innerHeight - bar
      const list = [0]
      for (const f of rollRef.current?.querySelectorAll('figure') ?? []) {
        const top = f.getBoundingClientRect().top + window.scrollY - bar - 10
        list.push(top)
        const h = f.offsetHeight + 20
        if (h > avail) list.push(top + h - avail)
      }
      list.push(document.documentElement.scrollHeight - window.innerHeight)
      return list.map((y) => Math.max(0, Math.round(y))).sort((a, b) => a - b)
    }
    const advance = (dir) => {
      // Mid-glide, count from where it's heading, so quick presses keep going a frame each.
      const from = target != null && performance.now() - targetAt < 600 ? target : window.scrollY
      const list = stops()
      const to = dir > 0 ? list.find((y) => y > from + 4) : [...list].reverse().find((y) => y < from - 4)
      if (to == null) return
      target = to; targetAt = performance.now()
      const smooth = !window.matchMedia('(prefers-reduced-motion: reduce)').matches
      window.scrollTo({ top: to, behavior: smooth ? 'smooth' : 'auto' })
    }

    const wheel = (e) => {
      if (e.ctrlKey || document.body.classList.contains('locked') || Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return
      e.preventDefault()
      const now = performance.now()
      const mag = Math.abs(e.deltaY), dir = Math.sign(e.deltaY)
      // One swipe is one step, but macOS keeps sending fading momentum events for a second after
      // the fingers lift. A new swipe shows up as scrolling that turns around, picks up again
      // after a pause, or climbs well above the low point of a tail that had faded, and counts
      // straight away. (`low` is the slowest since the last peak, so a swipe's own run-up never trips it.)
      if (mag >= peak) { peak = mag; low = mag } else low = Math.min(low, mag)
      const fresh = !gesture
        || (dir !== dirNow && mag > 3)
        || (now - stepAt > 120 && (now - lastAt > 70 || (mag > 6 && mag > low * 2.5 && low < peak * 0.5)))
      lastAt = now
      if (fresh) { peak = mag; low = mag }
      clearTimeout(quietTimer)
      quietTimer = setTimeout(() => { gesture = false }, 140)
      if (!fresh || mag < 2) return
      gesture = true; dirNow = dir; stepAt = now
      advance(dir)
    }
    const key = (e) => {
      if (document.body.classList.contains('locked') || e.target.closest?.('input, textarea, select, [contenteditable]')) return
      const dir = { ArrowDown: 1, PageDown: 1, ' ': e.shiftKey ? -1 : 1, ArrowUp: -1, PageUp: -1 }[e.key]
      if (!dir) return
      e.preventDefault()
      advance(dir)
    }
    window.addEventListener('wheel', wheel, { passive: false })
    window.addEventListener('keydown', key)
    return () => { window.removeEventListener('wheel', wheel); window.removeEventListener('keydown', key); clearTimeout(quietTimer) }
  }, [rollRef])
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

/** Just the photo you opened, as large as it fits and never cropped, with its likes, comments and tags. */
function Viewer({ batch, photo, me, isOwner, canTag, reactions, onClose, onStep, onLike, onCopy, onTag, onMakeCover, onRemove, onReport, onReportComment, onCommentCount }) {
  const [commentsOpen, setCommentsOpen] = useState(() => window.matchMedia('(min-width: 960px)').matches)
  const [showPins, setShowPins] = useState(true)
  const [wide, setWide] = useState(() => window.matchMedia('(min-width: 960px)').matches)
  useEffect(() => {
    const mq = window.matchMedia('(min-width: 960px)')
    const on = () => setWide(mq.matches)
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [])
  const index = batch.photos.indexOf(photo)
  const prev = batch.photos[index - 1] ?? null
  const next = batch.photos[index + 1] ?? null
  const swipe = useSwipe({ id: photo.id, hasPrev: !!prev, hasNext: !!next, onStep: (dir) => onStep(dir < 0 ? prev : next) })
  useEffect(() => {
    const key = (e) => {
      if (e.target.closest?.('textarea, input')) return
      if (e.key === 'Escape') onClose()
      else if (e.key === 'ArrowLeft') swipe.step(-1)
      else if (e.key === 'ArrowRight') swipe.step(1)
    }
    window.addEventListener('keydown', key)
    document.body.classList.add('locked')
    return () => { window.removeEventListener('keydown', key); document.body.classList.remove('locked') }
  }, [onClose, swipe.step])
  const tags = reactions?.tags ?? []
  const hasPins = tags.some((t) => t.x != null && t.y != null)

  return (
    <div className={`viewer ${commentsOpen && wide ? 'with-panel' : ''}`} role="dialog" aria-modal="true" aria-label={`Photo ${index + 1} of ${batch.title}`}>
      <div className="viewer-main" onClick={onClose}>
        <div className="viewer-top" onClick={(e) => e.stopPropagation()}>
          <button className="round dark" onClick={onClose} aria-label="Close"><Icon name="close" /></button>
          <span className="viewer-count">{String(index + 1).padStart(2, '0')} of {batch.photos.length}</span>
          <Menu className="dark" items={[
            canTag && { label: 'Tag people', icon: 'tag', onClick: onTag },
            onMakeCover && { label: 'Make cover', icon: 'star', onClick: onMakeCover },
            { label: 'Copy link to photo', icon: 'link', onClick: onCopy },
            onRemove && { label: 'Remove from batch', icon: 'trash', destructive: true, onClick: onRemove },
            onReport && { label: 'Report photo', icon: 'flag', onClick: onReport },
          ]} />
        </div>
        <div className="viewer-stage" ref={swipe.stageRef} {...swipe.handlers}>
          <div className="viewer-track" style={swipe.trackStyle} onTransitionEnd={swipe.onTransitionEnd}>
            {/* Keyed by photo, so the neighbour slid into view stays mounted and doesn't reload. */}
            {[prev, photo, next].map((p, k) => p && (
              <div key={p.id} className="viewer-slide" style={{ left: `${(k - 1) * 100}%` }} aria-hidden={p !== photo}>
                <div className="viewer-photo" onClick={(e) => e.stopPropagation()}
                     style={{ '--aspect': (p.pixel_width || 1) / (p.pixel_height || 1), aspectRatio: `${p.pixel_width || 1} / ${p.pixel_height || 1}` }}>
                  <Photo photo={p} tier="m" eager className="under" />
                  {p === photo && <Photo photo={p} tier="l" eager />}
                  {p === photo && showPins && tags.map((t) => t.x != null && t.y != null && (
                    <Link key={t.user_id} className="tag-pin" to={t.user ? `/app/u/${t.user.handle}` : '#'}
                          style={{ left: `${Math.min(92, Math.max(8, t.x * 100))}%`, top: `${Math.min(92, Math.max(8, t.y * 100))}%` }}>
                      @{t.user?.handle ?? 'tagged'}
                    </Link>
                  ))}
                </div>
              </div>
            ))}
          </div>
          {prev && <button className="round dark viewer-nav prev" onClick={(e) => { e.stopPropagation(); swipe.step(-1) }} aria-label="Previous photo"><Icon name="back" /></button>}
          {next && <button className="round dark viewer-nav next" onClick={(e) => { e.stopPropagation(); swipe.step(1) }} aria-label="Next photo"><Icon name="forward" /></button>}
        </div>
        <div className="viewer-bottom" onClick={(e) => e.stopPropagation()}>
          <div className="viewer-text">
            {photo.caption && <p className="caption">{photo.caption}</p>}
            {tags.length > 0 && (
              <div className="viewer-tags">
                <Icon name="tag" size={13} />
                {tags.map((t) => (
                  <Link key={t.user_id} className="viewer-tag-pill" to={t.user ? `/app/u/${t.user.handle}` : '#'}>
                    @{t.user?.handle ?? 'tagged'}
                  </Link>
                ))}
              </div>
            )}
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
              {(canTag || tags.length > 0) && (
                <button className="pill" onClick={onTag} aria-label={canTag ? 'Tag people' : 'Tagged people'}>
                  <Icon name="tag" /><span>{tags.length || ''}</span>
                </button>
              )}
              {hasPins && (
                <button className="pill" onClick={() => setShowPins(!showPins)}
                        aria-label={showPins ? 'Hide tag pins' : 'Show tag pins'}>
                  <Icon name={showPins ? 'eye' : 'eyeOff'} />
                </button>
              )}
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
 * Swiping between photos: the strip of neighbours follows the finger, then slides the rest of the
 * way (a long enough drag or a flick) or springs back. At either end it only gives a little.
 * `step` does the same slide for the arrow keys and buttons.
 */
function useSwipe({ id, hasPrev, hasNext, onStep }) {
  const stageRef = useRef(null)
  const [pos, setPos] = useState({ dx: 0, animate: false })
  const drag = useRef(null)
  const dragged = useRef(false)
  const pending = useRef(0)
  const latest = useRef({ hasPrev, hasNext, onStep })
  latest.current = { hasPrev, hasNext, onStep }

  // The new photo is now in the middle slot: put the strip back without animating.
  useLayoutEffect(() => { pending.current = 0; setPos({ dx: 0, animate: false }) }, [id])

  const settle = useCallback((dir) => {
    const { hasPrev, hasNext, onStep } = latest.current
    if (dir && !(dir < 0 ? hasPrev : hasNext)) dir = 0
    if (dir && window.matchMedia('(prefers-reduced-motion: reduce)').matches) { onStep(dir); return }
    const width = stageRef.current?.clientWidth ?? window.innerWidth
    pending.current = dir
    setPos({ dx: -dir * width, animate: true })
  }, [])
  const step = useCallback((dir) => { if (!pending.current && !drag.current) settle(dir) }, [settle])

  // Two-finger swipes on a trackpad arrive as horizontal wheel events. The strip follows them;
  // past a threshold it commits straight away, and the rest of that gesture (including macOS's
  // momentum events) is swallowed. If the fingers stop short, it springs back.
  useEffect(() => {
    const el = stageRef.current
    if (!el) return
    let dx = 0, idle = null, spent = false
    const end = () => {
      idle = null
      if (!spent && dx) settle(0)
      dx = 0; spent = false
    }
    const wheel = (e) => {
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY) || e.ctrlKey) return
      e.preventDefault()   // and no browser back/forward swipe
      clearTimeout(idle)
      idle = setTimeout(end, 160)
      if (spent || pending.current || drag.current) return
      const width = el.clientWidth || window.innerWidth
      dx -= e.deltaMode === 1 ? e.deltaX * 16 : e.deltaX
      const { hasPrev, hasNext } = latest.current
      if (Math.abs(dx) > width * 0.15 && (dx < 0 ? hasNext : hasPrev)) { spent = true; settle(dx < 0 ? 1 : -1); return }
      const atEnd = (dx > 0 && !hasPrev) || (dx < 0 && !hasNext)
      setPos({ dx: atEnd ? dx * 0.25 : dx, animate: false })
    }
    el.addEventListener('wheel', wheel, { passive: false })
    return () => { el.removeEventListener('wheel', wheel); clearTimeout(idle) }
  }, [settle])

  const onTransitionEnd = (e) => {
    if (e.target !== e.currentTarget) return
    const dir = pending.current
    if (dir) latest.current.onStep(dir)
    else setPos((p) => ({ ...p, animate: false }))
  }

  const handlers = {
    onPointerDown: (e) => {
      if (e.button !== 0 || pending.current || e.target.closest('button, a')) return
      drag.current = { id: e.pointerId, x: e.clientX, y: e.clientY, lastX: e.clientX, lastT: e.timeStamp, v: 0, axis: null }
      dragged.current = false
    },
    onPointerMove: (e) => {
      const d = drag.current
      if (!d || e.pointerId !== d.id) return
      const dx = e.clientX - d.x, dy = e.clientY - d.y
      if (!d.axis) {
        if (Math.hypot(dx, dy) < 8) return
        d.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y'
        if (d.axis === 'x') e.currentTarget.setPointerCapture(e.pointerId)
      }
      if (d.axis !== 'x') return
      dragged.current = true
      d.v = (e.clientX - d.lastX) / Math.max(1, e.timeStamp - d.lastT)
      d.lastX = e.clientX; d.lastT = e.timeStamp
      const { hasPrev, hasNext } = latest.current
      const atEnd = (dx > 0 && !hasPrev) || (dx < 0 && !hasNext)
      setPos({ dx: atEnd ? dx * 0.25 : dx, animate: false })
    },
    onPointerUp: (e) => {
      const d = drag.current
      drag.current = null
      if (!d || d.axis !== 'x') return
      const dx = e.clientX - d.x
      const width = stageRef.current?.clientWidth ?? window.innerWidth
      const flick = Math.abs(d.v) > 0.45 && Math.sign(d.v) === Math.sign(dx)
      settle(Math.abs(dx) > width * 0.18 || flick ? (dx < 0 ? 1 : -1) : 0)
    },
    onPointerCancel: () => { if (drag.current?.axis === 'x') settle(0); drag.current = null },
    // A drag that ends over the photo or the backdrop isn't a tap: don't open or close anything.
    onClickCapture: (e) => { if (dragged.current) { e.stopPropagation(); e.preventDefault(); dragged.current = false } },
  }
  const trackStyle = {
    transform: `translate3d(${pos.dx}px, 0, 0)`,
    transition: pos.animate ? 'transform .3s cubic-bezier(.2, .8, .2, 1)' : 'none',
  }
  return { stageRef, handlers, trackStyle, onTransitionEnd, step }
}

/**
 * Comments on one photo. They can't be edited; their author and the batch's owner can remove them,
 * and anyone else who sees them can report them.
 */
function Comments({ photo, batch, me, isOwner, panel, onClose, onCount, onReport }) {
  const [list, setList] = useState(null)
  const [draft, setDraft] = useState('')
  const [mentions, setMentions] = useState([])
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')
  const [confirming, setConfirming] = useState(null)
  const end = useRef(null)

  const mentionMatch = useMemo(() => {
    const m = draft.match(/(?:^|[^a-zA-Z0-9_.])@([a-zA-Z0-9_.]{0,24})$/)
    return m ? m[1].toLowerCase() : null
  }, [draft])

  useEffect(() => {
    if (mentionMatch === null) { setMentions([]); return }
    const t = setTimeout(() => {
      api.searchProfiles(mentionMatch, me.id).then((rows) => setMentions(rows.slice(0, 6))).catch(() => setMentions([]))
    }, 180)
    return () => clearTimeout(t)
  }, [mentionMatch, me.id])

  const insertMention = (handle) => {
    setDraft((d) => d.replace(/@[a-zA-Z0-9_.]{0,24}$/, `@${handle} `))
    setMentions([])
  }

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
                <p className="comment-text"><MentionText text={c.body} /></p>
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
      {mentions.length > 0 && (
        <div className="mention-suggestions" role="listbox" aria-label="Mention someone">
          {mentions.map((u) => (
            <button key={u.id} type="button" className="mention-chip" onClick={() => insertMention(u.handle)}>
              <Avatar user={u} size={20} /><span>@{u.handle}</span>
            </button>
          ))}
        </div>
      )}
      <form className="composer" onSubmit={post}>
        <textarea rows={1} placeholder="Add a comment · @ to mention" value={draft} maxLength={api.commentLimit} aria-label="Comment"
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

function TagsSheet({ photo, me, blocked, canManage, tags, onClose, onChange }) {
  const [pin, setPin] = useState(null)
  const [q, setQ] = useState('')
  const [results, setResults] = useState([])
  const [busyID, setBusyID] = useState(null)
  const [problem, setProblem] = useState('')
  const inputRef = useRef(null)

  useEffect(() => {
    if (!canManage) return
    const t = setTimeout(() => {
      api.searchProfiles(q, me.id)
        .then((rows) => setResults(rows.filter((u) => !blocked.has(u.id))))
        .catch(() => setResults([]))
    }, q ? 180 : 0)
    return () => clearTimeout(t)
  }, [q, me.id, canManage, blocked])

  const taggedIDs = new Set(tags.map((t) => t.user_id))
  const candidates = [me, ...results].filter((u) => u && !taggedIDs.has(u.id) && (
    !q.trim() || u.handle.includes(q.trim().replace(/^@/, '').toLowerCase()) || u.display_name.toLowerCase().includes(q.trim().toLowerCase())
  ))

  const placePin = (e) => {
    if (!canManage) return
    const rect = e.currentTarget.getBoundingClientRect()
    if (!rect.width || !rect.height) return
    const x = Math.min(0.96, Math.max(0.04, (e.clientX - rect.left) / rect.width))
    const y = Math.min(0.96, Math.max(0.04, (e.clientY - rect.top) / rect.height))
    setPin({ x, y })
    inputRef.current?.focus()
  }

  const add = async (user) => {
    setBusyID(user.id); setProblem('')
    try {
      const saved = await api.setTag({ photoID: photo.id, userID: user.id, x: pin?.x ?? null, y: pin?.y ?? null, me: me.id })
      onChange([...tags.filter((t) => t.user_id !== user.id), saved])
      setPin(null)
      setQ('')
    } catch (err) {
      setProblem(err.message)
    } finally {
      setBusyID(null)
    }
  }

  const remove = async (tag) => {
    setBusyID(tag.user_id); setProblem('')
    try {
      await api.removeTag(photo.id, tag.user_id)
      onChange(tags.filter((t) => t.user_id !== tag.user_id))
    } catch (err) {
      setProblem(err.message)
    } finally {
      setBusyID(null)
    }
  }

  return (
    <Sheet title={canManage ? 'Tag people' : 'In this photo'} onClose={onClose} className="tags-sheet">
      <div className={`tags-preview ${canManage ? 'tappable' : ''}`} onClick={placePin}>
        <Photo photo={photo} tier="m" eager />
        {tags.map((t) => t.x != null && t.y != null && (
          <Link key={t.user_id} className="tag-pin" to={t.user ? `/app/u/${t.user.handle}` : '#'}
                onClick={(e) => { e.stopPropagation(); onClose() }}
                style={{ left: `${Math.min(92, Math.max(8, t.x * 100))}%`, top: `${Math.min(92, Math.max(8, t.y * 100))}%` }}>
            @{t.user?.handle ?? 'tagged'}
          </Link>
        ))}
        {pin && <span className="tag-pin-dot" style={{ left: `${pin.x * 100}%`, top: `${pin.y * 100}%` }} />}
      </div>
      {canManage && (
        <div className="tags-hint">
          <span className="meta">{pin ? 'Pin placed — pick who is there below.' : 'Click anywhere on the photo to place a pin, or choose someone below.'}</span>
          {pin && <button type="button" className="link" onClick={() => setPin(null)}>Clear pin</button>}
        </div>
      )}
      {problem && <p className="problem">{problem}</p>}
      {tags.length > 0 && (
        <ul className="people compact">
          {tags.map((t) => {
            const canRemove = canManage || t.user_id === me.id || t.tagged_by === me.id
            return (
              <li key={t.user_id}>
                <Link to={t.user ? `/app/u/${t.user.handle}` : '#'} className="byline" onNavigate={onClose}>
                  <Avatar user={t.user} size={34} />
                  <span className="who"><b>{t.user?.display_name ?? 'Someone'}</b><span className="meta">@{t.user?.handle ?? ''}</span></span>
                </Link>
                {canRemove && (
                  <button className="secondary" disabled={busyID === t.user_id} onClick={() => remove(t)}>
                    {t.user_id === me.id && !canManage ? 'Remove me' : 'Remove'}
                  </button>
                )}
              </li>
            )
          })}
        </ul>
      )}
      {!canManage && !tags.length && <p className="meta empty-note">Nobody is tagged in this photo.</p>}
      {canManage && (
        <div className="tags-picker">
          <input ref={inputRef} type="search" placeholder="Search name or @handle" value={q}
                 onChange={(e) => setQ(e.target.value)} aria-label="Search people to tag" />
          <ul className="people compact">
            {candidates.slice(0, 10).map((u) => (
              <li key={u.id}>
                <span className="byline">
                  <Avatar user={u} size={34} />
                  <span className="who"><b>{u.display_name}</b><span className="meta">@{u.handle}</span></span>
                </span>
                <button className="primary" disabled={busyID !== null} onClick={() => add(u)}>Tag</button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </Sheet>
  )
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

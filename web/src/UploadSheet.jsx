import { useCallback, useEffect, useRef, useState } from 'react'
import * as api from './api.js'
import {
  GooglePhotosCancelledError,
  GooglePhotosConfigError,
  pickFromGooglePhotos,
} from './googlePhotos.js'
import { defaultFrame, fontFamily, fonts, insets } from './look.js'
import { Avatar, Icon, Sheet, batchURL, counted } from './ui.jsx'
import { MAX_BATCH_PHOTOS, preparePhotoFile, releasePreparedPhoto } from './upload.js'

const frameKinds = [
  { kind: 'whiteBorder', title: 'White' },
  { kind: 'none', title: 'None' },
  { kind: 'thinBlack', title: 'Thin black' },
  { kind: 'polaroid', title: 'Polaroid' },
  { kind: 'filmStrip', title: 'Film strip' },
  { kind: 'galleryMat', title: 'Gallery mat' },
]

const fontOptions = [
  { id: 'classic', title: 'Classic' },
  { id: 'modern', title: 'Modern' },
  { id: 'rounded', title: 'Rounded' },
  { id: 'typewriter', title: 'Typewriter' },
  { id: 'didot', title: 'Didot' },
  { id: 'futura', title: 'Futura' },
  { id: 'handwritten', title: 'Handwritten' },
]

const backgroundOptions = [
  { id: 'light', title: 'Light', swatch: '#f3f3f3' },
  { id: 'desk', title: 'Linen', swatch: '#ddd4c1' },
  { id: 'kraft', title: 'Kraft', swatch: '#ccb087' },
  { id: 'dark', title: 'Dark', swatch: '#181715' },
]

const audienceOptions = [
  { id: 'private', title: 'Only me', brief: 'Private on your desk', icon: 'lock' },
  { id: 'people', title: 'Specific people', brief: 'Only people you add', icon: 'users' },
  { id: 'followers', title: 'Followers', brief: 'Followers + anyone added', icon: 'users' },
  { id: 'public', title: 'Anyone on Batches', brief: 'Public link & Batches', icon: 'globe' },
]

const fanOffsets = [
  { angle: -2, x: 0, y: 0 },
  { angle: 6, x: 40, y: -7 },
  { angle: -8, x: -42, y: 6 },
  { angle: 4, x: 16, y: 12 },
]

export function GooglePhotosMark({ size = 18 }) {
  return (
    <svg className="icon gp-mark" width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path fill="#EA4335" d="M12 12V4.5a3.75 3.75 0 017.5 0c0 .4-.33.75-.75.75H12V12z" />
      <path fill="#FBBC04" d="M12 12H4.5a3.75 3.75 0 010-7.5c.4 0 .75.33.75.75V12H12z" />
      <path fill="#34A853" d="M12 12v7.5a3.75 3.75 0 01-7.5 0c0-.4.33-.75.75-.75H12V12z" />
      <path fill="#4285F4" d="M12 12h7.5a3.75 3.75 0 010 7.5c-.4 0-.75-.33-.75-.75V12H12z" />
    </svg>
  )
}

function PreviewPrint({ item, frame, style }) {
  const [t, r, b, l] = insets(frame)
  const scale = 0.45
  return (
    <div
      className={`frame frame-${frame.kind} upload-fan-print`}
      style={{
        padding: `${Math.round(t * scale)}px ${Math.round(r * scale)}px ${Math.round(b * scale)}px ${Math.round(l * scale)}px`,
        ...style,
      }}
    >
      <img
        src={item.previewURL}
        alt=""
        style={{ aspectRatio: `${item.pixelWidth} / ${item.pixelHeight}` }}
        draggable={false}
      />
    </div>
  )
}

/**
 * Shared photo chooser used by both NewBatchSheet and AddPhotosSheet: local files (drag & drop or
 * file dialog, including HEIC) and Google Photos Picker API, with full-frame previews, captions,
 * ordering and removal.
 */
function PhotoSourcePicker({
  items,
  setItems,
  maxPhotos = MAX_BATCH_PHOTOS,
  frame = defaultFrame,
  disabled = false,
  initialFiles = null,
  autoStartGooglePhotos = false,
  showCoverStar = false,
  onNotice,
  onError,
}) {
  const fileInputRef = useRef(null)
  const itemsRef = useRef(items)
  itemsRef.current = items
  const gpAbortRef = useRef(null)
  const [dragging, setDragging] = useState(false)
  const dragDepth = useRef(0)
  const [preparingCount, setPreparingCount] = useState(0)
  const [gpStatus, setGpStatus] = useState(null)
  const [gpNeedsConfig, setGpNeedsConfig] = useState(false)

  const remaining = Math.max(0, maxPhotos - items.length)

  const ingestFiles = useCallback(async (fileList) => {
    const raw = Array.from(fileList || []).filter(Boolean)
    if (!raw.length) return
    onError?.('')
    const slots = Math.max(0, maxPhotos - itemsRef.current.length)
    if (slots <= 0) {
      onError?.(`A batch holds up to ${maxPhotos} photos at a time.`)
      return
    }
    const chosen = raw.slice(0, slots)
    if (raw.length > slots) {
      onNotice?.(`Kept the first ${counted(slots, 'photo')} (batches hold up to ${maxPhotos}).`)
    }
    setPreparingCount((n) => n + chosen.length)
    const prepared = []
    const failures = []
    for (const file of chosen) {
      try {
        prepared.push(await preparePhotoFile(file))
      } catch (err) {
        failures.push(err?.message || `Couldn't read ${file.name}`)
      } finally {
        setPreparingCount((n) => Math.max(0, n - 1))
      }
    }
    if (prepared.length) {
      setItems((prev) => [...prev, ...prepared])
    }
    if (failures.length) {
      onError?.(failures[0] + (failures.length > 1 ? ` (+${failures.length - 1} more)` : ''))
    }
  }, [maxPhotos, onError, onNotice, setItems])

  const startGooglePhotos = useCallback(async () => {
    if (disabled || gpStatus) return
    const slots = Math.max(0, maxPhotos - itemsRef.current.length)
    if (slots <= 0) {
      onError?.(`You've already picked ${maxPhotos} photos.`)
      return
    }
    onError?.('')
    setGpNeedsConfig(false)
    const ctrl = new AbortController()
    gpAbortRef.current = ctrl
    setGpStatus({ stage: 'authorizing' })
    try {
      const { photos, skippedVideos } = await pickFromGooglePhotos({
        maxCount: slots,
        signal: ctrl.signal,
        onStatus: (next) => setGpStatus(next),
      })
      if (photos.length) {
        setItems((prev) => [...prev, ...photos])
      }
      if (skippedVideos > 0) {
        onNotice?.(`Skipped ${counted(skippedVideos, 'video')} — Batches is for photos.`)
      } else if (!photos.length) {
        onNotice?.('No photos were selected in Google Photos.')
      }
    } catch (err) {
      if (err instanceof GooglePhotosCancelledError) {
        // Quietly return to the sheet when the user closes or cancels the picker.
      } else if (err instanceof GooglePhotosConfigError) {
        setGpNeedsConfig(true)
      } else {
        onError?.(err?.message || "Couldn't import from Google Photos.")
      }
    } finally {
      gpAbortRef.current = null
      setGpStatus(null)
    }
  }, [disabled, gpStatus, maxPhotos, onError, onNotice, setItems])

  const cancelGooglePhotos = () => {
    gpAbortRef.current?.abort()
  }

  useEffect(() => () => { gpAbortRef.current?.abort() }, [])

  const didInitRef = useRef(false)
  useEffect(() => {
    if (didInitRef.current) return
    didInitRef.current = true
    if (initialFiles?.length) ingestFiles(initialFiles)
    else if (autoStartGooglePhotos) startGooglePhotos()
  }, [autoStartGooglePhotos, ingestFiles, initialFiles, startGooglePhotos])

  const removeItem = (localID) => {
    setItems((prev) => {
      const found = prev.find((x) => x.localID === localID)
      if (found) releasePreparedPhoto(found)
      return prev.filter((x) => x.localID !== localID)
    })
  }

  const clearAll = () => {
    setItems((prev) => {
      prev.forEach(releasePreparedPhoto)
      return []
    })
  }

  const moveItem = (index, delta) => {
    setItems((prev) => {
      const target = index + delta
      if (target < 0 || target >= prev.length) return prev
      const copy = [...prev]
      const [moved] = copy.splice(index, 1)
      copy.splice(target, 0, moved)
      return copy
    })
  }

  const makeFirst = (index) => {
    if (index <= 0) return
    setItems((prev) => {
      const copy = [...prev]
      const [picked] = copy.splice(index, 1)
      return [picked, ...copy]
    })
  }

  const setCaption = (localID, caption) => {
    setItems((prev) => prev.map((it) => (it.localID === localID ? { ...it, caption } : it)))
  }

  const previewFan = items.slice(0, fanOffsets.length)

  return (
    <div className="upload-picker">
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*,.heic,.heif"
        multiple
        hidden
        disabled={disabled}
        onChange={(e) => {
          const files = e.target.files
          if (files?.length) ingestFiles(files)
          e.target.value = ''
        }}
      />

      <div
        className={`upload-dropzone ${dragging ? 'dragging' : ''} ${items.length ? 'has-items' : ''}`}
        role="button"
        tabIndex={disabled ? -1 : 0}
        aria-label="Choose photos from your device or drop them here"
        onClick={() => { if (!disabled && remaining > 0) fileInputRef.current?.click() }}
        onKeyDown={(e) => {
          if (!disabled && remaining > 0 && (e.key === 'Enter' || e.key === ' ')) {
            e.preventDefault()
            fileInputRef.current?.click()
          }
        }}
        onDragEnter={(e) => {
          e.preventDefault()
          dragDepth.current += 1
          if (!disabled) setDragging(true)
        }}
        onDragOver={(e) => { e.preventDefault() }}
        onDragLeave={(e) => {
          e.preventDefault()
          dragDepth.current = Math.max(0, dragDepth.current - 1)
          if (dragDepth.current === 0) setDragging(false)
        }}
        onDrop={(e) => {
          e.preventDefault()
          dragDepth.current = 0
          setDragging(false)
          if (!disabled && e.dataTransfer?.files?.length) ingestFiles(e.dataTransfer.files)
        }}
      >
        {!previewFan.length ? (
          <div className="upload-empty-prompt">
            <Icon name="photo" size={28} />
            <b>Drop photos here or click to browse</b>
            <span className="meta">JPEG, PNG, HEIC or WebP · up to {maxPhotos}, always full frame</span>
          </div>
        ) : (
          <div className="upload-fan-stage" aria-hidden="true">
            {[...previewFan.entries()].reverse().map(([idx, item]) => {
              const f = fanOffsets[idx % fanOffsets.length]
              return (
                <PreviewPrint
                  key={item.localID}
                  item={item}
                  frame={frame}
                  style={{
                    transform: `translate(-50%, -50%) translate(${f.x}px, ${f.y}px) rotate(${f.angle}deg)`,
                    zIndex: previewFan.length - idx,
                  }}
                />
              )
            })}
            <span className="upload-fan-pill">
              {counted(items.length, 'photo')}{remaining > 0 ? ' · add more' : ''}
            </span>
          </div>
        )}
      </div>

      <div className="upload-sources">
        <button
          type="button"
          className="secondary"
          disabled={disabled || remaining <= 0}
          onClick={() => fileInputRef.current?.click()}
        >
          <Icon name="upload" size={17} />
          <span>Choose from device</span>
        </button>
        <button
          type="button"
          className="secondary gp-button"
          disabled={disabled || remaining <= 0 || Boolean(gpStatus)}
          onClick={startGooglePhotos}
        >
          <GooglePhotosMark size={17} />
          <span>Google Photos</span>
        </button>
      </div>

      {preparingCount > 0 && (
        <div className="upload-banner">
          <div className="spinner small" />
          <span className="meta">Reading {counted(preparingCount, 'photo')}…</span>
        </div>
      )}

      {gpStatus && (
        <div className="upload-banner gp-banner" role="status">
          <div className="spinner small" />
          <div className="upload-banner-body">
            {gpStatus.stage === 'authorizing' && <span>Connecting to Google Photos…</span>}
            {gpStatus.stage === 'creating-session' && <span>Starting Google Photos picker…</span>}
            {gpStatus.stage === 'picking' && (
              <span>
                {gpStatus.popupBlocked
                  ? 'Your browser held the picker window — open Google Photos below to pick your shots.'
                  : 'Choose your photos in the Google Photos window, then click Done.'}
              </span>
            )}
            {gpStatus.stage === 'listing' && <span>Fetching your chosen photos…</span>}
            {gpStatus.stage === 'downloading' && (
              <span>Importing {gpStatus.done} of {gpStatus.total} from Google Photos…</span>
            )}
          </div>
          <div className="upload-banner-actions">
            {gpStatus.stage === 'picking' && gpStatus.reopen && (
              <button type="button" className="primary compact" onClick={() => gpStatus.reopen()}>
                Open Google Photos
              </button>
            )}
            <button type="button" className="secondary compact" onClick={cancelGooglePhotos}>
              Cancel
            </button>
          </div>
        </div>
      )}

      {gpNeedsConfig && (
        <div className="upload-config-note" role="note">
          <b>Connect Google Photos</b>
          <p className="meta">
            Add <code>VITE_GOOGLE_CLIENT_ID</code> (an OAuth 2.0 Web Client ID with the Google Photos Picker API
            enabled) to <code>web/.env.local</code> or your Vercel project settings, then reload.
          </p>
        </div>
      )}

      {items.length > 0 && (
        <div className="upload-tray">
          <div className="upload-tray-head">
            <span className="meta">
              {counted(items.length, 'frame')} · full frame, location removed
            </span>
            {!disabled && (
              <button type="button" className="link" onClick={clearAll}>Clear all</button>
            )}
          </div>
          <ul className="upload-list">
            {items.map((item, idx) => (
              <li key={item.localID} className="upload-row">
                <div className="upload-thumb-box">
                  <img
                    src={item.previewURL}
                    alt={item.name}
                    style={{ aspectRatio: `${item.pixelWidth} / ${item.pixelHeight}` }}
                  />
                </div>
                <div className="upload-row-main">
                  <div className="upload-row-meta">
                    <span className="meta">
                      {String(idx + 1).padStart(2, '0')} · {item.pixelWidth} × {item.pixelHeight}
                    </span>
                    {item.sourceKind === 'google-photos' && (
                      <span className="gp-chip"><GooglePhotosMark size={11} /> Google Photos</span>
                    )}
                    {showCoverStar && idx === 0 && (
                      <span className="cover-tag"><Icon name="star" filled size={11} /> Cover</span>
                    )}
                    {showCoverStar && idx > 0 && !disabled && (
                      <button type="button" className="tag-chip quiet" onClick={() => makeFirst(idx)} title="Use as cover">
                        <Icon name="star" size={11} /><span>Make cover</span>
                      </button>
                    )}
                  </div>
                  <input
                    type="text"
                    className="upload-caption"
                    placeholder="Caption (optional)"
                    maxLength={200}
                    disabled={disabled}
                    value={item.caption}
                    onChange={(e) => setCaption(item.localID, e.target.value)}
                  />
                </div>
                {!disabled && (
                  <div className="upload-row-controls">
                    <button
                      type="button"
                      className="round tiny"
                      disabled={idx === 0}
                      aria-label="Move earlier"
                      onClick={() => moveItem(idx, -1)}
                    >
                      <Icon name="up" size={14} />
                    </button>
                    <button
                      type="button"
                      className="round tiny"
                      disabled={idx === items.length - 1}
                      aria-label="Move later"
                      onClick={() => moveItem(idx, 1)}
                    >
                      <Icon name="down" size={14} />
                    </button>
                    <button
                      type="button"
                      className="round tiny"
                      aria-label={`Remove ${item.name}`}
                      onClick={() => removeItem(item.localID)}
                    >
                      <Icon name="close" size={14} />
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

function FramePicker({ frame, onChange, disabled = false }) {
  return (
    <div className="look-group">
      <span className="label">Frame</span>
      <div className="frame-swatches" role="radiogroup" aria-label="Frame style">
        {frameKinds.map((opt) => {
          const on = frame.kind === opt.kind
          return (
            <button
              key={opt.kind}
              type="button"
              role="radio"
              aria-checked={on}
              disabled={disabled}
              className={`frame-swatch ${on ? 'on' : ''}`}
              onClick={() => onChange({ ...frame, kind: opt.kind })}
            >
              <span className={`swatch-card swatch-${opt.kind}`}><span className="swatch-photo" /></span>
              <span>{opt.title}</span>
            </button>
          )
        })}
      </div>
      {frame.kind !== 'filmStrip' && (
        <div className="seg-tabs compact-seg" role="radiogroup" aria-label="Column layout">
          <button
            type="button"
            role="radio"
            aria-checked={frame.layout !== 'twoColumn'}
            disabled={disabled}
            className={frame.layout !== 'twoColumn' ? 'on' : ''}
            onClick={() => onChange({ ...frame, layout: 'single' })}
          >
            Single column
          </button>
          <button
            type="button"
            role="radio"
            aria-checked={frame.layout === 'twoColumn'}
            disabled={disabled}
            className={frame.layout === 'twoColumn' ? 'on' : ''}
            onClick={() => onChange({ ...frame, layout: 'twoColumn' })}
          >
            Two columns
          </button>
        </div>
      )}
    </div>
  )
}

function AudiencePicker({ visibility, setVisibility, members, setMembers, me, blocked, disabled = false }) {
  const [q, setQ] = useState('')
  const [matches, setMatches] = useState([])

  useEffect(() => {
    if (!q.trim()) { setMatches([]); return }
    const t = setTimeout(() => {
      api.searchProfiles(q, me.id)
        .then((rows) => setMatches(rows.filter((u) => !blocked?.has(u.id))))
        .catch(() => setMatches([]))
    }, 200)
    return () => clearTimeout(t)
  }, [q, me.id, blocked])

  const memberIDs = new Set(members.map((m) => m.id))
  const candidates = matches.filter((u) => !memberIDs.has(u.id))

  const addPerson = (user) => {
    setMembers((prev) => [...prev, { ...user, can_add: false }])
    setQ('')
  }
  const toggleCanAdd = (id) => {
    setMembers((prev) => prev.map((m) => (m.id === id ? { ...m, can_add: !m.can_add } : m)))
  }
  const removePerson = (id) => {
    setMembers((prev) => prev.filter((m) => m.id !== id))
  }

  return (
    <div className="audience-picker">
      <span className="label">Who can see it</span>
      <div className="audience-grid" role="radiogroup" aria-label="Who can see this batch">
        {audienceOptions.map((opt) => {
          const on = visibility === opt.id
          return (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={on}
              disabled={disabled}
              className={`audience-card ${on ? 'on' : ''}`}
              onClick={() => setVisibility(opt.id)}
            >
              <div className="audience-card-top">
                <Icon name={opt.icon} size={17} />
                {on && <Icon name="check" size={16} />}
              </div>
              <b>{opt.title}</b>
              <span className="meta">{opt.brief}</span>
            </button>
          )
        })}
      </div>

      {(visibility === 'people' || visibility === 'followers') && (
        <div className="share-people-box">
          <span className="label">{visibility === 'people' ? 'People' : 'Also shared with'}</span>
          {members.length > 0 && (
            <ul className="people compact">
              {members.map((person) => (
                <li key={person.id}>
                  <span className="byline">
                    <Avatar user={person} size={32} />
                    <span className="who">
                      <b>{person.display_name}</b>
                      <span className="meta">@{person.handle}</span>
                    </span>
                  </span>
                  <div className="share-person-actions">
                    <button
                      type="button"
                      disabled={disabled}
                      className={person.can_add ? 'primary compact' : 'secondary compact'}
                      onClick={() => toggleCanAdd(person.id)}
                    >
                      {person.can_add ? 'Can add photos' : 'Can view'}
                    </button>
                    <button
                      type="button"
                      disabled={disabled}
                      className="round tiny"
                      aria-label={`Remove @${person.handle}`}
                      onClick={() => removePerson(person.id)}
                    >
                      <Icon name="close" size={14} />
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}
          <input
            type="search"
            placeholder="Add by name or @handle"
            disabled={disabled}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            aria-label="Add people by name or handle"
          />
          {candidates.length > 0 && (
            <ul className="people compact">
              {candidates.slice(0, 6).map((u) => (
                <li key={u.id}>
                  <span className="byline">
                    <Avatar user={u} size={30} />
                    <span className="who"><b>{u.display_name}</b><span className="meta">@{u.handle}</span></span>
                  </span>
                  <button type="button" className="primary compact" onClick={() => addPerson(u)}>Add</button>
                </li>
              ))}
            </ul>
          )}
          {visibility === 'people' && !members.length && (
            <p className="meta">Add at least one person, or choose Only me for now.</p>
          )}
        </div>
      )}
    </div>
  )
}

function UploadProgress({ progress }) {
  if (!progress) return null
  const pct = progress.total > 0 ? Math.round((progress.done / progress.total) * 100) : 0
  return (
    <div className="upload-progress" role="status">
      <div className="upload-progress-head">
        <span className="meta">
          Uploading {Math.min(progress.done + 1, progress.total)} of {progress.total}…
        </span>
        <span className="meta">{pct}%</span>
      </div>
      <div className="upload-progress-bar">
        <div className="upload-progress-fill" style={{ width: `${pct}%` }} />
      </div>
    </div>
  )
}

/** Create a brand-new batch from local files or Google Photos right on the web. */
export function NewBatchSheet({
  me,
  blocked,
  initialFiles = null,
  autoStartGooglePhotos = false,
  onClose,
  onCreated,
}) {
  const [items, setItems] = useState([])
  const itemsRef = useRef(items)
  itemsRef.current = items

  const [title, setTitle] = useState('')
  const [place, setPlace] = useState('')
  const [description, setDescription] = useState('')
  const [frame, setFrame] = useState(() => ({ ...defaultFrame }))
  const [visibility, setVisibility] = useState('private')
  const [members, setMembers] = useState([])
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState(null)
  const [notice, setNotice] = useState('')
  const [problem, setProblem] = useState('')

  useEffect(() => () => {
    itemsRef.current.forEach(releasePreparedPhoto)
  }, [])

  const handleClose = () => {
    if (busy) return
    onClose()
  }

  const canCreate = items.length > 0 && !busy && !(visibility === 'people' && members.length === 0)

  const submit = async (e) => {
    e.preventDefault()
    if (!canCreate) return
    setBusy(true)
    setProblem('')
    setNotice('')
    setProgress({ done: 0, total: items.length })
    try {
      const batchID = await api.createBatch({
        ownerID: me.id,
        title,
        place,
        description,
        frame,
        visibility,
        members,
        preparedPhotos: items,
        onProgress: setProgress,
      })
      onCreated(batchID)
    } catch (err) {
      setProblem(err?.message || "Couldn't create the batch.")
      setBusy(false)
      setProgress(null)
    }
  }

  return (
    <Sheet title="New batch" onClose={handleClose} className="upload-sheet">
      <form className="upload-form" onSubmit={submit}>
        <PhotoSourcePicker
          items={items}
          setItems={setItems}
          frame={frame}
          disabled={busy}
          initialFiles={initialFiles}
          autoStartGooglePhotos={autoStartGooglePhotos}
          showCoverStar
          onNotice={setNotice}
          onError={setProblem}
        />

        <div className="upload-fields">
          <div>
            <label className="label" htmlFor="batch-name">Name</label>
            <input
              id="batch-name"
              placeholder="Big Sur, one afternoon"
              maxLength={120}
              disabled={busy}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
            />
          </div>
          <div className="upload-two-col">
            <div>
              <label className="label" htmlFor="batch-place">Place</label>
              <input
                id="batch-place"
                placeholder="Optional"
                maxLength={120}
                disabled={busy}
                value={place}
                onChange={(e) => setPlace(e.target.value)}
              />
            </div>
            <div>
              <label className="label" htmlFor="batch-desc">Short note</label>
              <input
                id="batch-desc"
                placeholder="Under the title (optional)"
                maxLength={280}
                disabled={busy}
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
          </div>
        </div>

        <FramePicker frame={frame} onChange={setFrame} disabled={busy} />

        <AudiencePicker
          visibility={visibility}
          setVisibility={setVisibility}
          members={members}
          setMembers={setMembers}
          me={me}
          blocked={blocked}
          disabled={busy}
        />

        {notice && <p className="meta upload-notice">{notice}</p>}
        {problem && <p className="problem" role="alert">{problem}</p>}
        <UploadProgress progress={progress} />

        <div className="actions">
          <button type="button" className="secondary" disabled={busy} onClick={handleClose}>Cancel</button>
          <button type="submit" className="primary" disabled={!canCreate}>
            {busy ? 'Uploading…' : items.length ? `Make batch · ${counted(items.length, 'photo')}` : 'Choose photos to begin'}
          </button>
        </div>
      </form>
    </Sheet>
  )
}

/** Add photos from device or Google Photos into an existing batch (as owner or contributor). */
export function AddPhotosSheet({ batch, me, isOwner, onClose, onAdded }) {
  const [items, setItems] = useState([])
  const itemsRef = useRef(items)
  itemsRef.current = items

  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState(null)
  const [notice, setNotice] = useState('')
  const [problem, setProblem] = useState('')

  useEffect(() => () => {
    itemsRef.current.forEach(releasePreparedPhoto)
  }, [])

  const handleClose = () => {
    if (busy) return
    onClose()
  }

  const submit = async (e) => {
    e.preventDefault()
    if (!items.length || busy) return
    setBusy(true)
    setProblem('')
    setNotice('')
    setProgress({ done: 0, total: items.length })
    try {
      const updated = await api.addPhotosToBatch({
        batchID: batch.id,
        me: me.id,
        isOwner,
        existingPhotos: batch.photos,
        coverPhotoID: batch.cover_photo_id,
        preparedPhotos: items,
        onProgress: setProgress,
      })
      onAdded(updated, items.length)
    } catch (err) {
      setProblem(err?.message || "Couldn't add photos to this batch.")
      setBusy(false)
      setProgress(null)
    }
  }

  return (
    <Sheet title={`Add to ${batch.title}`} onClose={handleClose} className="upload-sheet">
      <form className="upload-form" onSubmit={submit}>
        {!isOwner && (
          <p className="sheet-text">
            Photos you add show up with your name, and you can remove your own anytime.
          </p>
        )}
        <PhotoSourcePicker
          items={items}
          setItems={setItems}
          frame={batch.frame}
          disabled={busy}
          onNotice={setNotice}
          onError={setProblem}
        />

        {notice && <p className="meta upload-notice">{notice}</p>}
        {problem && <p className="problem" role="alert">{problem}</p>}
        <UploadProgress progress={progress} />

        <div className="actions">
          <button type="button" className="secondary" disabled={busy} onClick={handleClose}>Cancel</button>
          <button type="submit" className="primary" disabled={!items.length || busy}>
            {busy ? 'Uploading…' : items.length ? `Add ${counted(items.length, 'photo')}` : 'Choose photos'}
          </button>
        </div>
      </form>
    </Sheet>
  )
}

/** Share settings for a batch owner on the web, matching SharePileSheet on iPhone. */
export function ShareBatchSheet({ batch, me, blocked, onClose, onSaved, onCopyLink }) {
  const [visibility, setVisibility] = useState(batch.visibility || 'private')
  const [members, setMembers] = useState([])
  const [loadingMembers, setLoadingMembers] = useState(true)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')

  useEffect(() => {
    let live = true
    api.batchMembers(batch.id)
      .then((rows) => { if (live) setMembers(rows) })
      .catch(() => {})
      .finally(() => { if (live) setLoadingMembers(false) })
    return () => { live = false }
  }, [batch.id])

  const canSave = !busy && !loadingMembers && !(visibility === 'people' && members.length === 0)

  const save = async () => {
    if (!canSave) return
    setBusy(true)
    setProblem('')
    try {
      await api.setBatchSharing(batch.id, visibility, members)
      onSaved(visibility)
    } catch (err) {
      setProblem(err?.message || "Couldn't update sharing.")
      setBusy(false)
    }
  }

  return (
    <Sheet title="Share batch" onClose={() => !busy && onClose()} className="upload-sheet">
      <div className="upload-form">
        <AudiencePicker
          visibility={visibility}
          setVisibility={setVisibility}
          members={members}
          setMembers={setMembers}
          me={me}
          blocked={blocked}
          disabled={busy || loadingMembers}
        />

        {visibility !== 'private' && (
          <div className="share-link-box">
            <div className="share-link-meta">
              <b>{batch.title}</b>
              <span className="meta">{window.location.host}{batchURL(batch.id)}</span>
            </div>
            <button type="button" className="secondary compact" onClick={onCopyLink}>
              <Icon name="link" size={16} /><span>Copy link</span>
            </button>
          </div>
        )}

        {problem && <p className="problem" role="alert">{problem}</p>}

        <div className="actions">
          <button type="button" className="secondary" disabled={busy} onClick={onClose}>Cancel</button>
          <button type="button" className="primary" disabled={!canSave} onClick={save}>
            {busy ? 'Saving…' : 'Done'}
          </button>
        </div>
      </div>
    </Sheet>
  )
}

/** Edit a batch's name, place, description, frame, font and background on the web. */
export function BatchLookSheet({ batch, onClose, onSaved }) {
  const [title, setTitle] = useState(batch.title || '')
  const [place, setPlace] = useState(batch.place || '')
  const [description, setDescription] = useState(batch.description || '')
  const [frame, setFrame] = useState(() => ({ ...defaultFrame, ...(batch.frame || {}) }))
  const [font, setFont] = useState(batch.font || 'classic')
  const [background, setBackground] = useState(batch.background || batch.frame?.wall || 'light')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')

  const save = async (e) => {
    e.preventDefault()
    if (!title.trim() || busy) return
    setBusy(true)
    setProblem('')
    try {
      const nextFrame = { ...frame, wall: api.legacyWallFor(background) }
      await api.updateBatch(batch.id, {
        title: title.trim(),
        place,
        description,
        frame: nextFrame,
        font,
        background,
      })
      onSaved()
    } catch (err) {
      setProblem(err?.message || "Couldn't save changes.")
      setBusy(false)
    }
  }

  return (
    <Sheet title="Batch look & details" onClose={() => !busy && onClose()} className="upload-sheet">
      <form className="upload-form" onSubmit={save}>
        <div className="upload-fields">
          <div>
            <label className="label" htmlFor="edit-batch-name">Name</label>
            <input
              id="edit-batch-name"
              maxLength={120}
              required
              disabled={busy}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
            />
          </div>
          <div className="upload-two-col">
            <div>
              <label className="label" htmlFor="edit-batch-place">Place</label>
              <input
                id="edit-batch-place"
                placeholder="Optional"
                maxLength={120}
                disabled={busy}
                value={place}
                onChange={(e) => setPlace(e.target.value)}
              />
            </div>
            <div>
              <label className="label" htmlFor="edit-batch-desc">Short note</label>
              <input
                id="edit-batch-desc"
                placeholder="Under the title (optional)"
                maxLength={280}
                disabled={busy}
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
          </div>
        </div>

        <FramePicker frame={frame} onChange={setFrame} disabled={busy} />

        <div className="look-group">
          <span className="label">Typeface</span>
          <div className="font-pills" role="radiogroup" aria-label="Batch typeface">
            {fontOptions.map((f) => (
              <button
                key={f.id}
                type="button"
                role="radio"
                aria-checked={font === f.id}
                disabled={busy}
                className={`font-pill ${font === f.id ? 'on' : ''}`}
                style={{ fontFamily: fonts[f.id] ?? fontFamily(f.id) }}
                onClick={() => setFont(f.id)}
              >
                {f.title}
              </button>
            ))}
          </div>
        </div>

        {frame.kind !== 'filmStrip' && (
          <div className="look-group">
            <span className="label">Wall</span>
            <div className="wall-pills" role="radiogroup" aria-label="Wall background">
              {backgroundOptions.map((bg) => (
                <button
                  key={bg.id}
                  type="button"
                  role="radio"
                  aria-checked={background === bg.id}
                  disabled={busy}
                  className={`wall-pill ${background === bg.id ? 'on' : ''}`}
                  onClick={() => setBackground(bg.id)}
                >
                  <span className="wall-dot" style={{ background: bg.swatch }} />
                  <span>{bg.title}</span>
                </button>
              ))}
            </div>
          </div>
        )}

        {problem && <p className="problem" role="alert">{problem}</p>}

        <div className="actions">
          <button type="button" className="secondary" disabled={busy} onClick={onClose}>Cancel</button>
          <button type="submit" className="primary" disabled={!title.trim() || busy}>
            {busy ? 'Saving…' : 'Save'}
          </button>
        </div>
      </form>
    </Sheet>
  )
}

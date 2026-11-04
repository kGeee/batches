import { useCallback, useEffect, useMemo, useState } from 'react'
import * as api from './api.js'

// Routes: #/ desk · #/friends · #/people · #/pile/<id> · #/u/<handle>
function useRoute() {
  const read = () => window.location.hash.replace(/^#\/?/, '').split('/')
  const [route, setRoute] = useState(read)
  useEffect(() => {
    const on = () => setRoute(read())
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])
  return route
}

export default function App() {
  const [session, setSession] = useState(undefined)   // undefined = still loading
  const [me, setMe] = useState(undefined)

  useEffect(() => {
    api.supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data } = api.supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) { setMe(session === null ? null : undefined); return }
    api.profile(session.user.id).then(setMe).catch(() => setMe(null))
  }, [session])

  if (session === undefined || (session && me === undefined)) return <Splash />
  if (!session) return <SignIn />
  if (!me) return <CreateProfile userID={session.user.id} email={session.user.email} onDone={setMe} />
  return <Signed me={me} />
}

function Splash() {
  return <div className="center"><div className="spinner" /></div>
}

// Account ----------------------------------------------------------------------------------------

function SignIn() {
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState('')

  const run = async (work) => {
    setBusy(true); setProblem('')
    try { await work() } catch (e) { setProblem(e.message) } finally { setBusy(false) }
  }

  return (
    <div className="signin">
      <PrintStack />
      <h1 className="wordmark">Strewn</h1>
      <p className="lede">Your photos in piles, full frame, shared with the people who were there.</p>
      {!sent ? (
        <form onSubmit={(e) => { e.preventDefault(); run(async () => { await api.sendSignInEmail(email.trim()); setSent(true) }) }}>
          <input type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus required />
          <button className="primary wide" disabled={busy || !email.includes('@')}>Email me a sign-in link</button>
        </form>
      ) : (
        <form onSubmit={(e) => { e.preventDefault(); run(() => api.verifyCode(email.trim(), code)) }}>
          <p>We sent a sign-in link to <b>{email}</b>. Open it on this computer.</p>
          <p className="meta">If the email has a six-digit code instead, enter it here.</p>
          <input inputMode="numeric" placeholder="123456" value={code} maxLength={6}
                 onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} className="code" />
          <button className="primary wide" disabled={busy || code.length !== 6}>Sign in</button>
          <button type="button" className="link" onClick={() => { setSent(false); setCode('') }}>Use a different email</button>
        </form>
      )}
      {problem && <p className="problem">{problem}</p>}
    </div>
  )
}

function CreateProfile({ userID, email, onDone }) {
  const [name, setName] = useState('')
  const [handle, setHandle] = useState(email?.split('@')[0].toLowerCase().replace(/[^a-z0-9_.]/g, '').slice(0, 24) ?? '')
  const [available, setAvailable] = useState(null)
  const [problem, setProblem] = useState('')
  const valid = /^[a-z0-9_.]{3,24}$/.test(handle)

  useEffect(() => {
    setAvailable(null)
    if (!valid) return
    const t = setTimeout(() => api.isHandleAvailable(handle).then(setAvailable), 300)
    return () => clearTimeout(t)
  }, [handle, valid])

  return (
    <div className="signin">
      <h1 className="title">Make your profile</h1>
      <p className="lede">This is how friends find you.</p>
      <form onSubmit={async (e) => {
        e.preventDefault()
        try { onDone(await api.createProfile(userID, handle, name.trim())) } catch (err) { setProblem(err.message) }
      }}>
        <input placeholder="Your name" value={name} onChange={(e) => setName(e.target.value)} maxLength={60} autoFocus />
        <div className="handle">
          <span>@</span>
          <input placeholder="handle" value={handle} onChange={(e) => setHandle(e.target.value.toLowerCase())} maxLength={24} />
        </div>
        <p className="meta">
          {!handle ? '3–24 letters, numbers, _ or .' : !valid ? 'Only a–z, 0–9, _ and ., at least 3.'
            : available === null ? 'Checking…' : available ? '✓ Available' : 'Taken'}
        </p>
        <button className="primary wide" disabled={!name.trim() || !valid || !available}>Continue</button>
      </form>
      {problem && <p className="problem">{problem}</p>}
    </div>
  )
}

// Signed in --------------------------------------------------------------------------------------

function Signed({ me }) {
  const route = useRoute()
  const [following, setFollowing] = useState(new Set())
  const refreshFollowing = useCallback(() => api.followingIDs(me.id).then(setFollowing), [me.id])
  useEffect(() => { refreshFollowing() }, [refreshFollowing])

  const toggleFollow = async (user) => {
    if (following.has(user.id)) await api.unfollow(me.id, user.id)
    else await api.follow(me.id, user.id)
    refreshFollowing()
  }
  const ctx = { me, following, toggleFollow }

  const [page, arg] = route
  let body
  if (page === 'pile' && arg) body = <PilePage id={arg} ctx={ctx} />
  else if (page === 'friends') body = <Friends ctx={ctx} />
  else if (page === 'people') body = <People ctx={ctx} />
  else if (page === 'u' && arg) body = <ProfilePage handle={arg} ctx={ctx} />
  else body = <Desk ctx={ctx} />

  return (
    <div className="app">
      {page !== 'pile' && (
        <nav className="tabs">
          <a href="#/" className={!page ? 'on' : ''}>Desk</a>
          <a href="#/friends" className={page === 'friends' ? 'on' : ''}>Friends</a>
          <a href="#/people" className={page === 'people' ? 'on' : ''}>Find people</a>
          <span className="spacer" />
          <span className="meta">@{me.handle}</span>
          <button className="link" onClick={api.signOut}>Sign out</button>
        </nav>
      )}
      {body}
    </div>
  )
}

function useLoad(load, deps) {
  const [state, setState] = useState({ data: null, error: null, loading: true })
  const reload = useCallback(() => {
    setState((s) => ({ ...s, loading: true }))
    load().then((data) => setState({ data, error: null, loading: false }))
      .catch((error) => setState({ data: null, error, loading: false }))
  }, deps) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { reload() }, [reload])
  return { ...state, reload }
}

function Desk({ ctx }) {
  const { me } = ctx
  const { data: piles, error, reload } = useLoad(() => api.pilesOf(me.id), [me.id])
  const [creating, setCreating] = useState(false)
  const frames = piles?.reduce((n, p) => n + p.photos.length, 0) ?? 0

  return (
    <main>
      <header className="deskhead">
        <div>
          <h1 className="title big">{me.display_name}</h1>
          <p className="meta">{piles?.length ?? 0} piles · {frames} frames · {me.follower_count} followers · {me.following_count} following</p>
        </div>
        <button className="fab" onClick={() => setCreating(true)} title="New pile">+</button>
        <Avatar user={me} size={44} />
      </header>
      {error && <p className="problem">{error.message}</p>}
      {piles && !piles.length && (
        <div className="card empty">
          <h2 className="title">Your desk is clear</h2>
          <p>Make a pile here, then add photos to it from the Strewn app on your phone.</p>
          <button className="primary" onClick={() => setCreating(true)}>New pile</button>
        </div>
      )}
      <div className="grid">
        {piles?.map((p) => <PileCard key={p.id} pile={p} showVisibility />)}
      </div>
      {creating && <NewPile me={me} onClose={() => setCreating(false)} onCreated={() => { setCreating(false); reload() }} />}
    </main>
  )
}

function Friends({ ctx }) {
  const { data: piles, error } = useLoad(() => api.feed(ctx.me.id), [ctx.me.id, ctx.following])
  return (
    <main>
      <h1 className="title big">Friends</h1>
      {error && <p className="problem">{error.message}</p>}
      {piles && !piles.length && (
        <div className="card empty">
          <h2 className="title">Nothing here yet</h2>
          <p>Follow friends to see the piles they share with followers. Piles shared with you directly show up here too.</p>
          <a className="primary button" href="#/people">Find people</a>
        </div>
      )}
      <div className="feed">
        {piles?.map((p) => (
          <div key={p.id} className="card">
            <a className="byline" href={`#/u/${p.owner?.handle}`}>
              <Avatar user={p.owner} size={34} />
              <span>
                <b>{p.owner?.display_name}</b>
                <span className="meta">@{p.owner?.handle} · {relative(p.created_at)}</span>
              </span>
              {p.visibility === 'people' && <span className="badge">For you</span>}
            </a>
            <PileCard pile={p} />
          </div>
        ))}
      </div>
    </main>
  )
}

function People({ ctx }) {
  const [q, setQ] = useState('')
  const [results, setResults] = useState([])
  useEffect(() => {
    const t = setTimeout(() => api.searchProfiles(q, ctx.me.id).then(setResults).catch(() => setResults([])), 250)
    return () => clearTimeout(t)
  }, [q, ctx.me.id])
  return (
    <main>
      <h1 className="title big">Find people</h1>
      <input placeholder="Name or @handle" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
      <ul className="people">
        {results.map((u) => (
          <li key={u.id}>
            <a href={`#/u/${u.handle}`} className="byline">
              <Avatar user={u} size={40} />
              <span><b>{u.display_name}</b><span className="meta">@{u.handle}</span></span>
            </a>
            <FollowButton user={u} ctx={ctx} />
          </li>
        ))}
        {!results.length && <li className="meta">No one matches yet.</li>}
      </ul>
    </main>
  )
}

function ProfilePage({ handle, ctx }) {
  const { data, error } = useLoad(async () => {
    const user = await api.profileByHandle(handle)
    return user ? { user, piles: await api.pilesOf(user.id) } : null
  }, [handle, ctx.following])
  if (error) return <main><p className="problem">{error.message}</p></main>
  if (!data) return <main>{data === null ? <p>No one is called @{handle}.</p> : <Splash />}</main>
  const { user, piles } = data
  const isMe = user.id === ctx.me.id
  return (
    <main>
      <header className="deskhead">
        <Avatar user={user} size={64} />
        <div>
          <h1 className="title big">{user.display_name}</h1>
          <p className="meta">@{user.handle} · {piles.length} piles you can see · {user.follower_count} followers</p>
        </div>
        <span className="spacer" />
        {!isMe && <FollowButton user={user} ctx={ctx} />}
      </header>
      {!piles.length && <p className="meta">Nothing of {user.display_name}'s is shared with you yet.</p>}
      <div className="grid">{piles.map((p) => <PileCard key={p.id} pile={p} showVisibility={isMe} />)}</div>
    </main>
  )
}

function FollowButton({ user, ctx }) {
  const on = ctx.following.has(user.id)
  return <button className={on ? 'secondary' : 'primary'} onClick={() => ctx.toggleFollow(user)}>{on ? 'Following' : 'Follow'}</button>
}

// A pile -----------------------------------------------------------------------------------------

/** The collapsed pile: up to four prints, loosely stacked, cover on top. */
function PileCard({ pile, showVisibility }) {
  const stack = useMemo(() => {
    const cover = pile.photos.find((p) => p.id === pile.cover_photo_id) ?? pile.photos[0]
    return [...pile.photos.filter((p) => p !== cover).slice(0, 3), cover].filter(Boolean)
  }, [pile])
  const vis = api.visibilities.find((v) => v.id === pile.visibility)
  return (
    <a className="pile" href={`#/pile/${pile.id}`}>
      <div className="stack">
        {stack.length === 0 && <div className="print empty">No photos yet</div>}
        {stack.map((photo, i) => (
          <div key={photo.id} className="print" style={{
            transform: `translate(-50%, -50%) rotate(${tilt(photo.id, i === stack.length - 1)}deg)`,
            zIndex: i,
            width: photo.pixel_width >= photo.pixel_height ? '78%' : `${78 * photo.pixel_width / photo.pixel_height}%`,
          }}>
            <Photo photo={photo} tier="s" />
          </div>
        ))}
      </div>
      <h3 className="title">{showVisibility && <span className="vis" title={vis?.title}>{vis?.symbol} </span>}{pile.title}</h3>
      <p className="meta">{pile.photos.length} frames{pile.shot_on ? ` · ${shortDate(pile.shot_on)}` : ''}{pile.place ? ` · ${pile.place}` : ''}</p>
    </a>
  )
}

function PilePage({ id, ctx }) {
  const { data: p, error, reload } = useLoad(() => api.pile(id), [id])
  const [viewing, setViewing] = useState(null)
  const [sharing, setSharing] = useState(false)
  if (error) return <main><p className="problem">{error.message}</p></main>
  if (p === null) return <main><a href="#/">← Desk</a><p>This pile doesn't exist, or it isn't shared with you.</p></main>
  if (!p) return <Splash />
  const isOwner = p.owner_id === ctx.me.id
  const frame = p.frame
  const vis = api.visibilities.find((v) => v.id === p.visibility)

  return (
    // Film strips are negatives: always on a dark wall, as in the app.
    <div className={`wall wall-${frame.kind === 'filmStrip' ? 'dark' : frame.wall}`}>
      <header className="gallerybar">
        <button className="round" onClick={() => history.length > 1 ? history.back() : (location.hash = '#/')} title="Back">‹</button>
        <span className="spacer" />
        {isOwner && <button className="round" onClick={() => setSharing(true)} title={`Share · ${vis?.title}`}>{vis?.symbol}</button>}
      </header>
      <section className="intro">
        <h1 className="title big">{p.title}</h1>
        <p className="meta">{[p.shot_on && longDate(p.shot_on), p.place, `${p.photos.length} frames`].filter(Boolean).join(' · ')}</p>
        {!isOwner && p.owner && <a className="byline" href={`#/u/${p.owner.handle}`}><Avatar user={p.owner} size={24} /><b>{p.owner.display_name}</b></a>}
      </section>
      <div className={frame.layout === 'twoColumn' ? 'masonry' : 'column'}>
        {p.photos.map((photo, i) => (
          <figure key={photo.id}>
            <div className={`frame frame-${frame.kind}`} style={{ '--border': `${frame.borderWidth}px` }} onClick={() => setViewing(i)}>
              <Photo photo={photo} tier="l" />
              {frame.kind === 'polaroid' && photo.caption && <span className="handwritten">{photo.caption}</span>}
              {frame.kind === 'filmStrip' && <span className="edge">STREWN 400 <span>▸ {String(i + 1).padStart(2, '0')}A</span></span>}
            </div>
            {frame.layout !== 'twoColumn' && (
              <figcaption className="meta">
                {String(i + 1).padStart(2, '0')}{photo.exif?.iso ? ` · ISO ${photo.exif.iso}` : ''}{photo.edit ? ' · edited' : ''}
                {photo.id === p.cover_photo_id && <span className="cover">★ Cover</span>}
                {isOwner && photo.id !== p.cover_photo_id && (
                  <button className="link small" onClick={async () => { await api.setCover(p.id, photo.id); reload() }}>Make cover</button>
                )}
              </figcaption>
            )}
          </figure>
        ))}
      </div>
      {!p.photos.length && <p className="meta center-text">No photos yet. Add them from the Strewn app.</p>}
      {viewing !== null && <Viewer photos={p.photos} index={viewing} onIndex={setViewing} onClose={() => setViewing(null)} />}
      {sharing && <ShareSheet pile={p} me={ctx.me} onClose={() => setSharing(false)} onSaved={() => { setSharing(false); reload() }} />}
    </div>
  )
}

function Viewer({ photos, index, onIndex, onClose }) {
  const photo = photos[index]
  useEffect(() => {
    const key = (e) => {
      if (e.key === 'Escape') onClose()
      if (e.key === 'ArrowRight' && index < photos.length - 1) onIndex(index + 1)
      if (e.key === 'ArrowLeft' && index > 0) onIndex(index - 1)
    }
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  }, [index, photos.length, onClose, onIndex])
  return (
    <div className="viewer" onClick={onClose}>
      <div className="viewer-top">
        <button className="round dark" onClick={onClose}>✕</button>
        <span>{index + 1} of {photos.length}</span>
        <span style={{ width: 40 }} />
      </div>
      <div className="viewer-photo" onClick={(e) => e.stopPropagation()}><Photo photo={photo} tier="l" /></div>
      <div className="viewer-bottom" onClick={(e) => e.stopPropagation()}>
        {photo.caption && <p>{photo.caption}</p>}
        <p className="meta light">{photo.pixel_width} × {photo.pixel_height} · uncropped</p>
        <div className="thumbs">
          {photos.map((ph, i) => (
            <button key={ph.id} className={i === index ? 'on' : ''} onClick={() => onIndex(i)}><Photo photo={ph} tier="s" /></button>
          ))}
        </div>
      </div>
    </div>
  )
}

function ShareSheet({ pile, me, onClose, onSaved }) {
  const [visibility, setVisibility] = useState(pile.visibility)
  const [people, setPeople] = useState([])
  const [q, setQ] = useState('')
  const [matches, setMatches] = useState([])
  const [busy, setBusy] = useState(false)
  useEffect(() => { api.members(pile.id).then(setPeople) }, [pile.id])
  useEffect(() => {
    if (!q.trim()) { setMatches([]); return }
    const t = setTimeout(() => api.searchProfiles(q, me.id).then(setMatches), 250)
    return () => clearTimeout(t)
  }, [q, me.id])
  const withPeople = visibility === 'people' || visibility === 'followers'

  return (
    <div className="sheet-bg" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()}>
        <h2 className="title">Share pile</h2>
        {api.visibilities.map((v) => (
          <label key={v.id} className={`option ${visibility === v.id ? 'on' : ''}`}>
            <input type="radio" checked={visibility === v.id} onChange={() => setVisibility(v.id)} />
            <span className="sym">{v.symbol}</span>
            <span><b>{v.title}</b><span className="meta">{v.detail}</span></span>
          </label>
        ))}
        {withPeople && (
          <div className="members">
            <p className="label">{visibility === 'people' ? 'People' : 'Also share with'}</p>
            {people.map((u) => (
              <div key={u.id} className="byline">
                <Avatar user={u} size={28} /><span><b>{u.display_name}</b> <span className="meta">@{u.handle}</span></span>
                <button className="link" onClick={() => setPeople(people.filter((x) => x.id !== u.id))}>Remove</button>
              </div>
            ))}
            <input placeholder="Add by name or @handle" value={q} onChange={(e) => setQ(e.target.value)} />
            {matches.filter((m) => !people.some((x) => x.id === m.id)).map((m) => (
              <button key={m.id} className="byline match" onClick={() => { setPeople([...people, m]); setQ('') }}>
                <Avatar user={m} size={28} /><span><b>{m.display_name}</b> <span className="meta">@{m.handle}</span></span><span>＋</span>
              </button>
            ))}
          </div>
        )}
        <div className="actions">
          <button className="secondary" onClick={onClose}>Cancel</button>
          <button className="primary" disabled={busy || (visibility === 'people' && !people.length)}
                  onClick={async () => { setBusy(true); await api.setSharing(pile.id, visibility, people); onSaved() }}>Done</button>
        </div>
      </div>
    </div>
  )
}

function NewPile({ me, onClose, onCreated }) {
  const [title, setTitle] = useState('')
  const [place, setPlace] = useState('')
  const [problem, setProblem] = useState('')
  return (
    <div className="sheet-bg" onClick={onClose}>
      <form className="sheet" onClick={(e) => e.stopPropagation()} onSubmit={async (e) => {
        e.preventDefault()
        try { await api.createPile(me.id, title.trim() || 'Untitled pile', place.trim()); onCreated() } catch (err) { setProblem(err.message) }
      }}>
        <h2 className="title">New pile</h2>
        <input placeholder="Big Sur, one afternoon" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus />
        <input placeholder="Place (optional)" value={place} onChange={(e) => setPlace(e.target.value)} />
        <p className="meta">New piles start as Only me. Photos are added from the phone, which uploads small shared copies; RAW files stay on the phone.</p>
        {problem && <p className="problem">{problem}</p>}
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>Cancel</button>
          <button className="primary">Create</button>
        </div>
      </form>
    </div>
  )
}

// Small pieces -----------------------------------------------------------------------------------

/**
 * One photo at its true shape (known before the bytes arrive), never cropped. Shared copies are
 * HEIC: Safari shows them; browsers without HEIC support fall back to an empty frame.
 */
function Photo({ photo, tier }) {
  const [failed, setFailed] = useState(false)
  const url = photo.urls?.[tier] ?? photo.urls?.l ?? photo.urls?.m
  return (
    <div className="photo" style={{ aspectRatio: `${photo.pixel_width} / ${photo.pixel_height}` }}>
      {url && !failed
        ? <img src={url} alt={photo.caption ?? ''} loading="lazy" onError={() => setFailed(true)} />
        : <span className="noimg">{url ? 'HEIC — open in Safari' : ''}</span>}
    </div>
  )
}

const hues = [8, 28, 50, 120, 172, 216, 270]
function Avatar({ user, size }) {
  const h = hues[hash(user?.id ?? '') % hues.length]
  return (
    <span className="avatar" style={{
      width: size, height: size, fontSize: size * 0.42,
      background: `linear-gradient(135deg, hsl(${h} 45% 45%), hsl(${h + 28} 55% 62%))`,
    }}>{user?.display_name?.[0]?.toUpperCase()}</span>
  )
}

function PrintStack() {
  return (
    <div className="stack hero">
      {[-8, 6, -2].map((r, i) => <div key={i} className="print" style={{ transform: `translate(-50%, -50%) rotate(${r}deg)`, width: '70%' }}>
        <div className="photo" style={{ aspectRatio: '3 / 2', background: `linear-gradient(${150 + i * 20}deg, #6aa7e8, #e89a4a)` }} />
      </div>)}
    </div>
  )
}

function hash(s) {
  let h = 2166136261
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619)
  h ^= h >>> 16; h = Math.imul(h, 0x85ebca6b); h ^= h >>> 13; h = Math.imul(h, 0xc2b2ae35); h ^= h >>> 16
  return h >>> 0
}
const tilt = (id, isTop) => isTop ? (hash(id) % 5) - 2 : (hash(id) % 17) - 8
const shortDate = (d) => new Date(d).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
const longDate = (d) => new Date(d).toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })
function relative(d) {
  const days = Math.round((Date.now() - new Date(d)) / 86400000)
  return days < 1 ? 'today' : days === 1 ? 'yesterday' : days < 30 ? `${days} days ago` : shortDate(d)
}

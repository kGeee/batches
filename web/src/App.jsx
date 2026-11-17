import { useCallback, useEffect, useMemo, useState } from 'react'
import * as api from './api.js'
import { clearPhotos } from './photos.js'
import { fontFamily } from './look.js'
import BatchPage from './Batch.jsx'
import { BooksPage, NewBookPage, PickableBatch } from './book/Books.jsx'
import { BookScreen } from './book/Book.jsx'
import { Avatar, Icon, Link, MentionText, Menu, Photo, Pile, Spinner, appURL, batchURL, counted, go, parseRoute, relative, shortDate, useLocation } from './ui.jsx'

export default function App() {
  const loc = useLocation()
  const route = parseRoute(loc.pathname, loc.search)
  const [session, setSession] = useState(undefined)   // undefined while restoring
  const [me, setMe] = useState(undefined)
  const [linkProblem, setLinkProblem] = useState(null)
  const [signingIn, setSigningIn] = useState(false)

  useEffect(() => {
    // An email link comes back with ?code= (or an error). supabase-js trades the code for a
    // session; the address is then tidied so a reload or a copied link doesn't carry it.
    const params = new URLSearchParams(window.location.search)
    const hash = new URLSearchParams(window.location.hash.slice(1))
    const fromLink = params.has('code') || params.has('error') || hash.has('error')
    const error = params.get('error_description') ?? hash.get('error_description')
    api.supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (fromLink) {
        if (!data.session) {
          setLinkProblem(error ?? 'That sign-in link didn\'t work here. It only works in the browser you asked for it from, once. Enter the code from the email instead, or ask for a new one.')
        }
        for (const k of ['code', 'error', 'error_code', 'error_description']) params.delete(k)
        const q = params.toString()
        window.history.replaceState(window.history.state, '', window.location.pathname + (q ? `?${q}` : ''))
      }
    })
    const { data } = api.supabase.auth.onAuthStateChange((event, s) => {
      setSession(s)
      if (event === 'SIGNED_OUT') clearPhotos()
    })
    return () => data.subscription.unsubscribe()
  }, [])

  const userID = session?.user?.id
  useEffect(() => {
    if (!userID) { setMe(session === null ? null : undefined); return }
    setMe(undefined)
    api.profile(userID).then(setMe).catch(() => setMe(null))
  }, [userID]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    document.title = route.page === 'batch' ? 'A batch on Batches' : 'Batches'
  }, [route.page])

  if (session === undefined || (session && me === undefined)) return <Spinner />
  if (!session && route.page === 'batch' && !signingIn && !linkProblem) {
    // A public batch opens for anyone with the link; anything else falls back to signing in.
    const guest = { me: null, blocked: noOne, signIn: () => setSigningIn(true) }
    return <BatchPage key={route.id} id={route.id} photoID={route.photo} ctx={guest}
                      signInInstead={<SignIn shared={route} linkProblem={linkProblem} />} />
  }
  if (!session) return <SignIn shared={route.page === 'batch' ? route : null} linkProblem={linkProblem} />
  if (!me) return <CreateProfile userID={session.user.id} email={session.user.email} onDone={setMe} />
  return <Signed me={me} route={route} />
}

const noOne = new Set()

// Signing in -------------------------------------------------------------------------------------

function friendly(error) {
  const m = error?.message ?? String(error)
  if (error?.status === 429 || /rate limit|security purposes|too many/i.test(m)) {
    return 'Too many sign-in emails have gone out in the last little while. Wait a few minutes and try again, or use the code from an email you already have.'
  }
  if (/expired|invalid|otp/i.test(m)) return "That code didn't work. Check it, or ask for a new one."
  return m
}

function SignIn({ shared, linkProblem }) {
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState(linkProblem ?? '')

  const run = async (work) => {
    setBusy(true); setProblem('')
    try { await work() } catch (e) { setProblem(friendly(e)) } finally { setBusy(false) }
  }
  // The email's link comes back to this same page, so a shared link opens straight after.
  const returnTo = window.location.origin + window.location.pathname + window.location.search

  return (
    <main className="signin">
      <a className="brand" href="/"><img src="/img/icon.png" alt="" width="34" height="34" /><span>Batches</span></a>
      <div className="card signin-card">
        {shared ? (
          <>
            <h1 className="title big">A batch on Batches</h1>
            <p className="lede">Someone shared a batch of photos with you.</p>
            <a className="button primary wide" href={appURL(shared.id, shared.photo)}>Open in Batches</a>
            <p className="or"><span>No app? Sign in to see it here</span></p>
          </>
        ) : (
          <>
            <h1 className="title big">Sign in</h1>
            <p className="lede">See your desk, your friends' batches, and every photo full frame.</p>
          </>
        )}
        {!sent ? (
          <form onSubmit={(e) => { e.preventDefault(); run(async () => { await api.sendCode(email.trim(), returnTo); setSent(true) }) }}>
            <label className="label" htmlFor="email">Email</label>
            <input id="email" type="email" autoComplete="email" placeholder="you@example.com" value={email}
                   onChange={(e) => setEmail(e.target.value)} required autoFocus={!shared} />
            <button className={`${shared ? 'secondary' : 'primary'} wide`} disabled={busy || !/.+@.+\..+/.test(email.trim())}>
              {busy ? 'Sending…' : 'Email me a code'}
            </button>
          </form>
        ) : (
          <form onSubmit={(e) => { e.preventDefault(); run(() => api.verifyCode(email.trim(), code)) }}>
            <p>We emailed a code to <b>{email.trim()}</b>.</p>
            <label className="label" htmlFor="code">Code</label>
            <input id="code" className="code" inputMode="numeric" autoComplete="one-time-code" placeholder="123456"
                   value={code} maxLength={8} autoFocus onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
            <button className="primary wide" disabled={busy || code.length < 6}>{busy ? 'Signing in…' : 'Sign in'}</button>
            <p className="meta">If the email has a link instead, open it in this browser.</p>
            <button type="button" className="link" onClick={() => { setSent(false); setCode(''); setProblem('') }}>Use a different email</button>
          </form>
        )}
        {problem && <p className="problem" role="alert">{problem}</p>}
      </div>
      <p className="fineprint meta">
        {shared ? 'Only people the owner shared it with can see it. ' : ''}
        <a href="/privacy">Privacy</a> · <a href="/support">Support</a>
      </p>
    </main>
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
    const t = setTimeout(() => api.isHandleAvailable(handle).then(setAvailable).catch(() => setAvailable(null)), 300)
    return () => clearTimeout(t)
  }, [handle, valid])

  return (
    <main className="signin">
      <div className="card signin-card">
        <h1 className="title big">Make your profile</h1>
        <p className="lede">This is how friends find you and share batches with you.</p>
        <form onSubmit={async (e) => {
          e.preventDefault()
          try { onDone(await api.createProfile(userID, handle, name.trim())) } catch (err) { setProblem(err.message) }
        }}>
          <label className="label" htmlFor="name">Name</label>
          <input id="name" placeholder="Your name" value={name} onChange={(e) => setName(e.target.value)} maxLength={60} autoFocus />
          <label className="label" htmlFor="handle">Handle</label>
          <div className="handle">
            <span>@</span>
            <input id="handle" placeholder="handle" value={handle} onChange={(e) => setHandle(e.target.value.toLowerCase())} maxLength={24} />
          </div>
          <p className="meta">
            {!handle ? '3–24 letters, numbers, _ or .' : !valid ? 'Only a–z, 0–9, _ and ., at least 3.'
              : available === null ? 'Checking…' : available ? '✓ Available' : 'Taken'}
          </p>
          <button className="primary wide" disabled={!name.trim() || !valid || !available}>Continue</button>
        </form>
        {problem && <p className="problem">{problem}</p>}
        <button className="link" onClick={() => api.signOut()}>Sign out</button>
      </div>
    </main>
  )
}

// Signed in --------------------------------------------------------------------------------------

function Signed({ me, route }) {
  const [following, setFollowing] = useState(new Set())
  const [blocked, setBlocked] = useState(new Set())
  const [notes, setNotes] = useState([])
  const refreshFollowing = useCallback(() => api.followingIDs(me.id).then(setFollowing).catch(() => {}), [me.id])
  const refreshNotifications = useCallback(() => api.notifications(me.id).then(setNotes).catch(() => {}), [me.id])
  useEffect(() => {
    refreshFollowing()
    refreshNotifications()
    api.blockedIDs(me.id).then(setBlocked).catch(() => {})
  }, [refreshFollowing, refreshNotifications, me.id])

  useEffect(() => {
    const channel = api.supabase
      .channel(`notifications:${me.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: `recipient_id=eq.${me.id}` }, () => {
        refreshNotifications()
      })
      .subscribe()
    return () => { api.supabase.removeChannel(channel) }
  }, [me.id, refreshNotifications])

  const toggleFollow = async (user) => {
    if (following.has(user.id)) await api.unfollow(me.id, user.id)
    else await api.follow(me.id, user.id)
    refreshFollowing()
  }
  const visibleNotes = useMemo(() => notes.filter((n) => !blocked.has(n.actor_id)), [notes, blocked])
  const unreadCount = useMemo(() => visibleNotes.filter((n) => !n.read_at).length, [visibleNotes])
  const markRead = useCallback(async (ids) => {
    const set = new Set(ids)
    const now = new Date().toISOString()
    setNotes((prev) => prev.map((n) => (set.has(n.id) && !n.read_at ? { ...n, read_at: now } : n)))
    await api.markNotificationsRead(ids).catch(() => {})
  }, [])
  const ctx = useMemo(
    () => ({ me, following, blocked, toggleFollow, notes: visibleNotes, unreadCount, markRead, refreshNotifications }),
    [me, following, blocked, visibleNotes, unreadCount, markRead, refreshNotifications] // eslint-disable-line react-hooks/exhaustive-deps
  )

  if (route.page === 'batch') return <BatchPage key={route.id} id={route.id} photoID={route.photo} ctx={ctx} />
  if (route.page === 'book') return <BookScreen key={route.id} id={route.id} view={route.view} ctx={ctx} />

  let body
  if (route.page === 'books') body = <BooksPage ctx={ctx} />
  else if (route.page === 'newbook') body = <NewBookPage key={route.picked.join()} picked={route.picked} ctx={ctx} />
  else if (route.page === 'friends') body = <Friends ctx={ctx} />
  else if (route.page === 'notifications') body = <NotificationsPage ctx={ctx} />
  else if (route.page === 'people') body = <People ctx={ctx} />
  else if (route.page === 'profile') body = <ProfilePage key={route.handle} handle={route.handle} ctx={ctx} />
  else body = <Desk ctx={ctx} />

  const tab = (page, to, label, badge = 0) => (
    <Link to={to} className={route.page === page ? 'on' : ''} aria-current={route.page === page ? 'page' : undefined}>
      {label}{badge > 0 && <span className="tab-badge">{badge}</span>}
    </Link>
  )
  return (
    <div className="app">
      <header className="topbar">
        <Link className="brand" to="/app"><img src="/img/icon.png" alt="" width="30" height="30" /><span>Batches</span></Link>
        <nav className="tabs" aria-label="Sections">
          {tab('desk', '/app', 'Desk')}
          {tab(route.page === 'newbook' ? 'newbook' : 'books', '/app/books', 'Books')}
          {tab('friends', '/app/friends', 'Friends')}
          {tab('notifications', '/app/notifications', 'Notifications', unreadCount)}
          {tab('people', '/app/people', 'Find people')}
        </nav>
        <div className="me">
          <Link to={`/app/u/${me.handle}`} className="me-link" aria-label="Your profile"><Avatar user={me} size={32} /></Link>
          <Menu label="Account" items={[
            { label: `@${me.handle}`, onClick: () => go(`/app/u/${me.handle}`) },
            { label: 'Sign out', onClick: () => api.signOut() },
          ]} />
        </div>
      </header>
      {body}
    </div>
  )
}

function useLoad(load, deps) {
  const [state, setState] = useState({ data: undefined, error: null })
  useEffect(() => {
    let live = true
    setState((s) => ({ ...s, error: null }))
    load().then((data) => live && setState({ data, error: null }))
      .catch((error) => live && setState({ data: null, error }))
    return () => { live = false }
  }, deps) // eslint-disable-line react-hooks/exhaustive-deps
  return state
}

const visibilityTitle = { private: 'Only me', people: 'Specific people', followers: 'Followers', public: 'Anyone on Batches' }

/** Your own batches, in the order you arranged them in the app, groups and all. */
function Desk({ ctx }) {
  const { me } = ctx
  const { data, error } = useLoad(async () => {
    const [batches, layout] = await Promise.all([api.batchesOf(me.id), api.deskLayout(me.id).catch(() => ({}))])
    return { batches, layout }
  }, [me.id])
  const tiles = useMemo(() => (data ? deskTiles(data.batches, data.layout) : []), [data])
  const tilted = data?.layout?.tiltedPiles === true
  const frames = data?.batches.reduce((n, b) => n + b.photos.length, 0) ?? 0
  // Picking batches for a book, right on the desk.
  const [picking, setPicking] = useState(null)
  const card = (b) => picking
    ? <PickableBatch key={b.id} batch={b} on={picking.includes(b.id)} onToggle={() => setPicking((p) => (p.includes(b.id) ? p.filter((x) => x !== b.id) : [...p, b.id]))} />
    : <BatchCard key={b.id} batch={b} tilted={tilted} showVisibility />

  return (
    <main>
      <header className="pagehead profilehead">
        <div className="who">
          <h1 className="title big">{me.display_name}'s desk</h1>
          <p className="meta">{counted(data?.batches.length ?? 0, 'batch', 'batches')} · {counted(frames, 'frame')} · {counted(me.follower_count, 'follower')} · {me.following_count} following</p>
        </div>
        {data?.batches.some((b) => b.photos.length) && !picking && <button className="secondary" onClick={() => setPicking([])}>Make a book</button>}
      </header>
      {error && <p className="problem">{error.message}</p>}
      {data === undefined && <Spinner />}
      {data && !data.batches.length && (
        <div className="card empty">
          <h2 className="title">Your desk is clear</h2>
          <p>Make batches in Batches on your iPhone. They show up here, full frame, and anything you share shows up for your friends.</p>
        </div>
      )}
      <div className="grid">
        {tiles.map((t) => t.group ? (
          <section key={t.group.id} className="desk-group">
            <h2 className="title">{t.group.title || 'Group'}</h2>
            <div className="grid inner">{t.batches.map(card)}</div>
          </section>
        ) : card(t.batch))}
      </div>
      {picking && (
        <div className="pickbar">
          <span className="meta">{picking.length ? `${counted(picking.length, 'batch', 'batches')} for a book` : 'Pick the batches for a book'}</span>
          <button className="secondary" onClick={() => setPicking(null)}>Cancel</button>
          <button className="primary" disabled={!picking.length} onClick={() => go(`/app/books/new?b=${picking.join(',')}`)}>Continue</button>
        </div>
      )}
    </main>
  )
}

/** DeskLayout.tiles in the app: arranged order, new batches first, groups as one tile. */
function deskTiles(batches, layout) {
  const groups = Array.isArray(layout.groups) ? layout.groups : []
  const grouped = new Set(groups.flatMap((g) => (g.pileIDs ?? []).map((id) => String(id).toLowerCase())))
  const byKey = new Map()
  for (const b of batches) if (!grouped.has(b.id)) byKey.set(b.id, { batch: b })
  for (const g of groups) {
    const members = (g.pileIDs ?? []).map((id) => batches.find((b) => b.id === String(id).toLowerCase())).filter(Boolean)
    if (members.length) byKey.set(String(g.id).toLowerCase(), { group: g, batches: members })
  }
  const order = (Array.isArray(layout.order) ? layout.order : []).map((k) => String(k).toLowerCase()).filter((k) => byKey.has(k))
  const known = new Set(order)
  return [...[...byKey.keys()].filter((k) => !known.has(k)), ...order].map((k) => byKey.get(k))
}

function Friends({ ctx }) {
  const { data, error } = useLoad(() => api.feed(ctx.me.id), [ctx.me.id, ctx.following])
  const batches = data?.filter((b) => !ctx.blocked.has(b.owner_id))
  return (
    <main>
      <header className="pagehead"><h1 className="title big">Friends</h1></header>
      {error && <p className="problem">{error.message}</p>}
      {data === undefined && <Spinner />}
      {batches && !batches.length && (
        <div className="card empty">
          <h2 className="title">Nothing here yet</h2>
          <p>Follow friends to see the batches they share with followers. Batches shared with you directly show up here too.</p>
          <Link className="button primary" to="/app/people">Find people</Link>
        </div>
      )}
      <div className="feed">
        {batches?.map((b) => (
          <article key={b.id} className="card feed-card">
            <Link className="byline" to={`/app/u/${b.owner?.handle}`}>
              <Avatar user={b.owner} size={34} />
              <span className="who"><b>{b.owner?.display_name}</b><span className="meta">@{b.owner?.handle} · {relative(b.created_at)}</span></span>
              {b.visibility === 'people' && <span className="badge">For you</span>}
            </Link>
            <BatchCard batch={b} />
          </article>
        ))}
      </div>
    </main>
  )
}

function People({ ctx }) {
  const [q, setQ] = useState('')
  const [results, setResults] = useState(null)
  useEffect(() => {
    const t = setTimeout(() => api.searchProfiles(q, ctx.me.id).then(setResults).catch(() => setResults([])), 250)
    return () => clearTimeout(t)
  }, [q, ctx.me.id])
  const shown = results?.filter((u) => !ctx.blocked.has(u.id))
  return (
    <main>
      <header className="pagehead"><h1 className="title big">Find people</h1></header>
      <input type="search" placeholder="Name or @handle" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search people" />
      <ul className="people">
        {shown?.map((u) => (
          <li key={u.id}>
            <Link to={`/app/u/${u.handle}`} className="byline">
              <Avatar user={u} size={40} />
              <span className="who"><b>{u.display_name}</b><span className="meta">@{u.handle}</span></span>
            </Link>
            <FollowButton user={u} ctx={ctx} />
          </li>
        ))}
        {shown && !shown.length && <li className="meta">No one matches yet.</li>}
      </ul>
    </main>
  )
}

function NotificationsPage({ ctx }) {
  const { notes, markRead, refreshNotifications } = ctx
  const [unreadOnOpen] = useState(() => new Set(notes.filter((n) => !n.read_at).map((n) => n.id)))

  useEffect(() => {
    refreshNotifications()
  }, [refreshNotifications])

  useEffect(() => {
    const unread = notes.filter((n) => !n.read_at).map((n) => n.id)
    if (unread.length) markRead(unread)
  }, [notes, markRead])

  return (
    <main>
      <header className="pagehead"><h1 className="title big">Notifications</h1></header>
      {!notes.length && (
        <div className="card empty">
          <h2 className="title">No notifications yet</h2>
          <p>When someone tags you, mentions you, shares a batch, follows you, or reacts to your photos, it shows up here.</p>
        </div>
      )}
      {notes.length > 0 && (
        <ul className="notifications card">
          {notes.map((item) => {
            const href = item.collection_id
              ? batchURL(item.collection_id, item.photo_id)
              : item.actor?.handle ? `/app/u/${item.actor.handle}` : '/app'
            const isNew = unreadOnOpen.has(item.id) || !item.read_at
            return (
              <li key={item.id} className={isNew ? 'unread' : ''}>
                <Link to={href} className="notification-row">
                  <Avatar user={item.actor} size={36} />
                  <div className="notification-body">
                    <p className="notification-line">
                      <b>{item.actor?.display_name ?? 'Someone'}</b>{' '}
                      <NotificationCopy item={item} />
                    </p>
                    <p className="meta">
                      {[relative(item.created_at), item.collection?.title].filter(Boolean).join(' · ')}
                    </p>
                  </div>
                  {isNew && <span className="unread-dot" aria-label="New" />}
                  {item.photo && (
                    <div className="notification-thumb">
                      <Photo photo={item.photo} tier="s" />
                    </div>
                  )}
                </Link>
                {item.kind === 'follow' && item.actor && <FollowButton user={item.actor} ctx={ctx} />}
              </li>
            )
          })}
        </ul>
      )}
    </main>
  )
}

function NotificationCopy({ item }) {
  switch (item.kind) {
    case 'photo_like': return 'liked your photo'
    case 'photo_comment': return <>commented: <MentionText text={item.body} /></>
    case 'comment_mention': return <>mentioned you: <MentionText text={item.body} /></>
    case 'photo_tag': return 'tagged you in a photo'
    case 'batch_shared': return item.body === 'can_add' ? 'invited you to add photos to a batch' : 'shared a batch with you'
    case 'photo_added': {
      const n = Math.max(1, parseInt(item.body || '1', 10) || 1)
      return `added ${n === 1 ? 'a photo' : `${n} photos`} to your batch`
    }
    case 'follow': return 'started following you'
    default: return ''
  }
}

function ProfilePage({ handle, ctx }) {
  const [section, setSection] = useState('batches')
  const { data, error } = useLoad(async () => {
    const user = await api.profileByHandle(handle)
    if (!user || ctx.blocked.has(user.id)) return { user, batches: [], tagged: [] }
    const [batches, tagged] = await Promise.all([api.batchesOf(user.id), api.taggedBatchesOf(user.id)])
    return { user, batches, tagged: tagged.filter((b) => !ctx.blocked.has(b.owner_id)) }
  }, [handle, ctx.following, ctx.blocked])
  if (error) return <main><p className="problem">{error.message}</p></main>
  if (data === undefined) return <Spinner />
  if (!data.user) return <main><div className="card empty"><h2 className="title">No one is called @{handle}</h2></div></main>
  const { user, batches, tagged } = data
  const isMe = user.id === ctx.me.id
  const isBlocked = ctx.blocked.has(user.id)
  const shown = section === 'tagged' ? tagged : batches
  return (
    <main>
      <header className="pagehead profilehead">
        <Avatar user={user} size={64} />
        <div className="who">
          <h1 className="title big">{user.display_name}</h1>
          <p className="meta">@{user.handle} · {counted(user.follower_count, 'follower')} · {user.following_count} following</p>
        </div>
        {!isMe && !isBlocked && <FollowButton user={user} ctx={ctx} />}
      </header>
      {isBlocked && <div className="card empty"><p>You've blocked @{user.handle}. You can unblock them in Batches on your iPhone.</p></div>}
      {!isBlocked && (tagged.length > 0 || section === 'tagged') && (
        <div className="seg-tabs" role="tablist">
          <button role="tab" aria-selected={section === 'batches'} className={section === 'batches' ? 'on' : ''} onClick={() => setSection('batches')}>Batches</button>
          <button role="tab" aria-selected={section === 'tagged'} className={section === 'tagged' ? 'on' : ''} onClick={() => setSection('tagged')}>
            Tagged{tagged.length > 0 ? ` · ${tagged.length}` : ''}
          </button>
        </div>
      )}
      {!isBlocked && !shown.length && (
        <p className="meta">
          {section === 'tagged'
            ? (isMe ? 'Batches you are tagged in show up here.' : `No visible batches tag ${user.display_name} yet.`)
            : (isMe ? 'No batches yet.' : `Nothing of ${user.display_name}'s is shared with you yet.`)}
        </p>
      )}
      <div className="grid">{shown.map((b) => <BatchCard key={b.id} batch={b} showVisibility={isMe && b.owner_id === ctx.me.id} />)}</div>
    </main>
  )
}

function FollowButton({ user, ctx }) {
  const on = ctx.following.has(user.id)
  const [busy, setBusy] = useState(false)
  return (
    <button className={on ? 'secondary' : 'primary'} disabled={busy}
            onClick={async () => { setBusy(true); try { await ctx.toggleFollow(user) } finally { setBusy(false) } }}>
      {on ? 'Following' : 'Follow'}
    </button>
  )
}

function BatchCard({ batch, showVisibility, tilted }) {
  return (
    <Link className="batch-card" to={batchURL(batch.id)}>
      <Pile batch={batch} tilted={tilted} />
      <h3 className="card-title" style={{ fontFamily: fontFamily(batch.font) }}>{batch.title}</h3>
      <p className="meta">
        {counted(batch.photos.length, 'frame')}{batch.shot_on ? ` · ${shortDate(batch.shot_on)}` : ''}{batch.place ? ` · ${batch.place}` : ''}
        {showVisibility ? ` · ${visibilityTitle[batch.visibility] ?? ''}` : ''}
      </p>
    </Link>
  )
}

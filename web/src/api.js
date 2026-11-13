import { createClient } from '@supabase/supabase-js'
import { defaultFrame } from './look.js'

// The publishable key only: row level security in supabase/migrations decides what each
// signed-in person can read and write, exactly as it does for the iOS app.
export const supabase = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_ANON_KEY, {
  auth: { flowType: 'pkce', detectSessionInUrl: true, persistSession: true },
})

// collections and photos are linked twice (photos.collection_id and collections.cover_photo_id),
// so the photos embed names its foreign key.
const batchSelect = '*, photos!photos_collection_id_fkey(*), owner:profiles!owner_id(*)'

function check({ data, error }) {
  if (error) throw error
  return data
}

// Account ----------------------------------------------------------------------------------------

/**
 * Emails a six-digit code, and a link back to `returnTo` for when the email has only a link. The
 * address must be in the project's auth redirect URLs (supabase/config.toml).
 */
export async function sendCode(email, returnTo) {
  check(await supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: returnTo } }))
}

export async function verifyCode(email, token) {
  check(await supabase.auth.verifyOtp({ email, token, type: 'email' }))
}

export async function signOut() {
  await supabase.auth.signOut()
}

// People -----------------------------------------------------------------------------------------

export async function profile(id) {
  return check(await supabase.from('profiles').select().eq('id', id).maybeSingle())
}

export async function profileByHandle(handle) {
  return check(await supabase.from('profiles').select().eq('handle', handle.toLowerCase()).maybeSingle())
}

export async function isHandleAvailable(handle) {
  return !(await profileByHandle(handle))
}

export async function createProfile(id, handle, displayName) {
  return check(await supabase.from('profiles')
    .insert({ id, handle: handle.toLowerCase(), display_name: displayName }).select().single())
}

export async function searchProfiles(query, me) {
  let request = supabase.from('profiles').select().neq('id', me)
  const q = query.trim().replace(/^@/, '').toLowerCase().replace(/[^a-z0-9_. ]/g, '')
  if (q) request = request.or(`handle.ilike.${q}%,display_name.ilike.%${q}%`)
  return check(await request.order('handle').limit(30))
}

export async function followingIDs(me) {
  const rows = check(await supabase.from('follows').select('followee_id').eq('follower_id', me))
  return new Set(rows.map((r) => r.followee_id))
}

export async function follow(me, them) {
  check(await supabase.from('follows').upsert({ follower_id: me, followee_id: them }, { ignoreDuplicates: true }))
}

export async function unfollow(me, them) {
  check(await supabase.from('follows').delete().eq('follower_id', me).eq('followee_id', them))
}

/**
 * People you've blocked. Row level security already hides batches, photos, likes and comments
 * across a block in both directions; profiles stay readable, so lists leave these people out,
 * as the app does.
 */
export async function blockedIDs(me) {
  const rows = check(await supabase.from('blocks').select('blocked_id').eq('blocker_id', me))
  return new Set(rows.map((r) => r.blocked_id))
}

/** Your own desk arrangement from the app: its order, groups, and whether piles are tilted. */
export async function deskLayout(me) {
  const rows = check(await supabase.from('desk_layouts').select('layout').eq('owner_id', me).limit(1))
  const layout = rows[0]?.layout
  return layout && typeof layout === 'object' ? layout : {}
}

// Batches ----------------------------------------------------------------------------------------

export async function batchesOf(ownerID) {
  // Row level security returns only the batches the signed-in person may see.
  const rows = check(await supabase.from('collections').select(batchSelect)
    .eq('owner_id', ownerID).order('shot_on', { ascending: false, nullsFirst: false }))
  return finish(rows)
}

/** One batch, or null when it doesn't exist or isn't shared with you: the two look the same. */
export async function batch(id) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return null
  const rows = check(await supabase.from('collections').select(batchSelect).eq('id', id).limit(1))
  return (await finish(rows))[0] ?? null
}

/** Batches from people you follow and batches shared with you. RLS still has the last word. */
export async function feed(me) {
  const [followed, shared] = await Promise.all([
    followingIDs(me),
    supabase.from('collection_members').select('collection_id').eq('user_id', me).then(check),
  ])
  const anyOf = []
  if (followed.size) anyOf.push(`owner_id.in.(${[...followed].join(',')})`)
  if (shared.length) anyOf.push(`id.in.(${shared.map((s) => s.collection_id).join(',')})`)
  if (!anyOf.length) return []
  const rows = check(await supabase.from('collections').select(batchSelect)
    .or(anyOf.join(',')).neq('owner_id', me).order('created_at', { ascending: false }).limit(50))
  return finish(rows)
}

/** Sorts photos, fills in the frame's defaults, and finds who added photos to group batches. */
async function finish(rows) {
  for (const b of rows) {
    b.photos = (b.photos ?? []).sort((x, y) => x.sort_index - y.sort_index)
    b.frame = { ...defaultFrame, ...(b.frame && typeof b.frame === 'object' ? b.frame : {}) }
    b.board = b.board && typeof b.board === 'object' ? b.board : null
  }
  const adders = [...new Set(rows.flatMap((b) => b.photos.map((p) => p.added_by).filter(Boolean)))]
  if (adders.length) {
    const people = check(await supabase.from('profiles').select().in('id', adders))
    const byID = Object.fromEntries(people.map((p) => [p.id, p]))
    for (const b of rows) for (const p of b.photos) if (p.added_by) p.adder = byID[p.added_by] ?? null
  }
  return rows
}

// Likes and comments on photos -------------------------------------------------------------------

/** Like and comment counts by photo. Row level security leaves out people across a block. */
export async function reactions(photoIDs, me) {
  const result = Object.fromEntries(photoIDs.map((id) => [id, { likes: 0, liked: false, comments: 0 }]))
  if (!photoIDs.length) return result
  for (let i = 0; i < photoIDs.length; i += 100) {
    const ids = photoIDs.slice(i, i + 100)
    const [likes, comments] = await Promise.all([
      supabase.from('photo_likes').select('photo_id, user_id').in('photo_id', ids).then(check),
      supabase.from('photo_comments').select('photo_id').in('photo_id', ids).then(check),
    ])
    for (const l of likes) {
      result[l.photo_id].likes++
      if (l.user_id === me) result[l.photo_id].liked = true
    }
    for (const c of comments) result[c.photo_id].comments++
  }
  return result
}

export async function setLiked(liked, photoID, me) {
  if (liked) check(await supabase.from('photo_likes').upsert({ photo_id: photoID, user_id: me }, { ignoreDuplicates: true }))
  else check(await supabase.from('photo_likes').delete().eq('photo_id', photoID).eq('user_id', me))
}

export async function comments(photoID) {
  return check(await supabase.from('photo_comments')
    .select('id, photo_id, author_id, body, created_at, author:profiles!author_id(*)')
    .eq('photo_id', photoID).order('created_at'))
}

export const commentLimit = 500

export async function addComment(photoID, body, me) {
  const id = crypto.randomUUID()
  check(await supabase.from('photo_comments').insert({ id, photo_id: photoID, author_id: me, body }))
  return id
}

/** Allowed for the comment's author and the batch's owner. */
export async function deleteComment(id) {
  check(await supabase.from('photo_comments').delete().eq('id', id))
}

// Reports ----------------------------------------------------------------------------------------

export const reportReasons = [
  { id: 'spam', title: 'Spam' },
  { id: 'nudity', title: 'Nudity or sexual content' },
  { id: 'harassment', title: 'Harassment or bullying' },
  { id: 'violence', title: 'Violence or threats' },
  { id: 'copyright', title: 'Copyright' },
  { id: 'other', title: 'Something else' },
]

/** Reports can't be read back; the database fills in who and what from these ids. */
export async function report({ userID, batchID, photoID, commentID, reason, details }) {
  const row = { reason }
  if (userID) row.reported_user_id = userID
  if (batchID) row.collection_id = batchID
  if (photoID) row.photo_id = photoID
  if (commentID) row.comment_id = commentID
  if (details?.trim()) row.details = details.trim().slice(0, 1000)
  check(await supabase.from('reports').insert(row))
}

import { createClient } from '@supabase/supabase-js'

// The publishable key only: row level security in supabase/migrations decides what each
// signed-in person can read and write, exactly as it does for the iOS app.
export const supabase = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_ANON_KEY, {
  auth: { flowType: 'pkce', detectSessionInUrl: true, persistSession: true },
})

const pileSelect = '*, photos!photos_collection_id_fkey(*), owner:profiles!owner_id(*)'
const tiers = ['s', 'm', 'l']

export const visibilities = [
  { id: 'private', title: 'Only me', detail: 'Nobody else can see it.', symbol: '🔒' },
  { id: 'people', title: 'Specific people', detail: 'Only the people you add.', symbol: '👥' },
  { id: 'followers', title: 'Followers', detail: 'Your followers, plus anyone you add.', symbol: '👪' },
  { id: 'public', title: 'Anyone on Strewn', detail: 'Anyone signed in.', symbol: '🌐' },
]

function check({ data, error }) {
  if (error) throw error
  return data
}

// Account ----------------------------------------------------------------------------------------

export async function sendSignInEmail(email) {
  // The link comes back to this page. The address must be in the project's allowed
  // redirect URLs (supabase/config.toml, additional_redirect_urls).
  check(await supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: window.location.origin } }))
}

export async function verifyCode(email, token) {
  check(await supabase.auth.verifyOtp({ email, token, type: 'email' }))
}

export async function signOut() {
  await supabase.auth.signOut()
}

// Profiles ---------------------------------------------------------------------------------------

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
  const q = query.trim().replace(/^@/, '').toLowerCase()
  if (q) request = request.or(`handle.ilike.${q}%,display_name.ilike.%${q}%`)
  return check(await request.order('handle').limit(30))
}

// Follows ----------------------------------------------------------------------------------------

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

// Piles ------------------------------------------------------------------------------------------

export async function pilesOf(ownerID) {
  const rows = check(await supabase.from('collections').select(pileSelect)
    .eq('owner_id', ownerID).order('shot_on', { ascending: false, nullsFirst: false }))
  return withImages(rows)
}

export async function pile(id) {
  const rows = check(await supabase.from('collections').select(pileSelect).eq('id', id).limit(1))
  return (await withImages(rows))[0] ?? null
}

/** Piles from people you follow and piles shared with you. RLS still has the last word. */
export async function feed(me) {
  const [followed, shared] = await Promise.all([
    followingIDs(me),
    supabase.from('collection_members').select('collection_id').eq('user_id', me).then(check),
  ])
  const anyOf = []
  if (followed.size) anyOf.push(`owner_id.in.(${[...followed].join(',')})`)
  if (shared.length) anyOf.push(`id.in.(${shared.map((s) => s.collection_id).join(',')})`)
  if (!anyOf.length) return []
  const rows = check(await supabase.from('collections').select(pileSelect)
    .or(anyOf.join(',')).neq('owner_id', me).order('created_at', { ascending: false }).limit(50))
  return withImages(rows)
}

export async function createPile(ownerID, title, place) {
  return check(await supabase.from('collections')
    .insert({ owner_id: ownerID, title, place: place || null, shot_on: new Date().toISOString() })
    .select().single())
}

export async function deletePile(id) {
  check(await supabase.from('collections').delete().eq('id', id))
}

export async function setCover(pileID, photoID) {
  check(await supabase.from('collections').update({ cover_photo_id: photoID }).eq('id', pileID))
}

export async function members(pileID) {
  const rows = check(await supabase.from('collection_members')
    .select('profile:profiles!user_id(*)').eq('collection_id', pileID))
  return rows.map((r) => r.profile)
}

/** Who can see a pile. Members only count for "specific people" and "followers". */
export async function setSharing(pileID, visibility, people) {
  check(await supabase.from('collections').update({ visibility }).eq('id', pileID))
  check(await supabase.from('collection_members').delete().eq('collection_id', pileID))
  const kept = visibility === 'people' || visibility === 'followers' ? people : []
  if (kept.length) {
    check(await supabase.from('collection_members').insert(kept.map((p) => ({ collection_id: pileID, user_id: p.id }))))
  }
}

// Images -----------------------------------------------------------------------------------------

/**
 * Photos only reach the server as small shared copies ({owner}/{photo}/{rev}/{s|m|l}.heic in the
 * private `media` bucket); RAW files and originals stay on the phone. Viewers get signed links
 * that expire after six hours.
 */
async function withImages(piles) {
  const photos = piles.flatMap((p) => p.photos ?? [])
  const paths = photos.filter((p) => p.share_path).flatMap((p) => tiers.map((t) => `${p.share_path}/${t}.heic`))
  const byPath = {}
  if (paths.length) {
    const { data } = await supabase.storage.from('media').createSignedUrls(paths, 6 * 3600)
    for (const r of data ?? []) if (r.signedUrl && !r.error) byPath[r.path] = r.signedUrl
  }
  for (const p of photos) {
    p.urls = Object.fromEntries(tiers.map((t) => [t, p.share_path ? byPath[`${p.share_path}/${t}.heic`] : undefined]))
  }
  for (const p of piles) {
    p.photos = (p.photos ?? []).sort((a, b) => a.sort_index - b.sort_index)
    p.frame = { kind: 'whiteBorder', borderWidth: 14, wall: 'light', layout: 'single', ...(p.frame ?? {}) }
  }
  return piles
}

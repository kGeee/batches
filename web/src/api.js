import { createClient } from '@supabase/supabase-js'
import { defaultFrame } from './look.js'
import { seedPhotoCache } from './photos.js'
import { renderShareCopies } from './upload.js'

// The publishable key only: row level security in supabase/migrations decides what each
// signed-in person can read and write, exactly as it does for the iOS app.
export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL || 'https://placeholder.supabase.co',
  import.meta.env.VITE_SUPABASE_ANON_KEY || 'placeholder-anon-key',
  {
    auth: { flowType: 'pkce', detectSessionInUrl: true, persistSession: true },
  },
)

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

/**
 * Leaves for Apple and comes back to `returnTo` with ?code=, which supabase-js trades for a
 * session (see App's link handling). Needs the Apple provider's Services ID and secret set in
 * Supabase; the iOS app's native sign-in doesn't use them.
 */
export async function signInWithApple(returnTo) {
  check(await supabase.auth.signInWithOAuth({ provider: 'apple', options: { redirectTo: returnTo } }))
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

/** Batches by id, in the order asked. Ones no longer shared with you are left out. */
export async function batchesByIDs(ids) {
  const wanted = ids.filter((id) => /^[0-9a-f-]{36}$/i.test(id))
  if (!wanted.length) return []
  const rows = await finish(check(await supabase.from('collections').select(batchSelect).in('id', wanted)))
  const byID = new Map(rows.map((b) => [b.id, b]))
  return wanted.map((id) => byID.get(id)).filter(Boolean)
}

export async function photosByIDs(ids) {
  if (!ids.length) return []
  return check(await supabase.from('photos').select().in('id', ids))
}

// Creating and updating batches ------------------------------------------------------------------

const shareTiers = ['s', 'm', 'l']
const objectPaths = (sharePath) => (sharePath ? shareTiers.map((t) => `${sharePath}/${t}.heic`) : [])

export function legacyWallFor(background) {
  if (background === 'dark' || background === 'desk') return background
  if (typeof background === 'string' && /^#[0-9a-f]{6}$/i.test(background)) {
    const v = parseInt(background.slice(1), 16)
    const [r, g, b] = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((c) => c / 255)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5 ? 'light' : 'dark'
  }
  return 'light'
}

/** Uploads the three shared-copy tiers into the adder's folder of the `media` bucket. */
export async function publishPhotoCopies(adderID, photoID, copies, replacingPath = null) {
  const rev = crypto.randomUUID().replace(/-/g, '').slice(0, 8).toLowerCase()
  const sharePath = `${adderID.toLowerCase()}/${photoID.toLowerCase()}/${rev}`
  const uploaded = []
  try {
    await Promise.all(shareTiers.map(async (tier) => {
      const key = `${sharePath}/${tier}.heic`
      check(await supabase.storage.from('media').upload(key, copies[tier], {
        contentType: 'image/jpeg',
        cacheControl: '31536000',
        upsert: false,
      }))
      uploaded.push(key)
    }))
  } catch (err) {
    if (uploaded.length) await supabase.storage.from('media').remove(uploaded).catch(() => {})
    throw err
  }
  await seedPhotoCache(sharePath, copies).catch(() => {})
  if (replacingPath) {
    await supabase.storage.from('media').remove(objectPaths(replacingPath)).catch(() => {})
  }
  return sharePath
}

async function prepareAndPublishAll(adderID, items, onProgress) {
  const ready = []
  const uploadedPaths = []
  try {
    for (let i = 0; i < items.length; i++) {
      onProgress?.({ done: i, total: items.length })
      const item = items[i]
      const photoID = crypto.randomUUID().toLowerCase()
      const rendered = await renderShareCopies(item)
      const sharePath = await publishPhotoCopies(adderID, photoID, rendered.copies)
      uploadedPaths.push(sharePath)
      ready.push({
        id: photoID,
        pixel_width: rendered.pixelWidth,
        pixel_height: rendered.pixelHeight,
        caption: item.caption?.trim() ? item.caption.trim() : null,
        captured_at: item.capturedAt || null,
        exif: item.exif || null,
        share_path: sharePath,
      })
    }
    onProgress?.({ done: items.length, total: items.length })
    return { ready, uploadedPaths }
  } catch (err) {
    const keys = uploadedPaths.flatMap(objectPaths)
    if (keys.length) await supabase.storage.from('media').remove(keys).catch(() => {})
    throw err
  }
}

/**
 * Makes a new batch on the web: encodes and uploads every photo's s/m/l shared copies first, saves
 * the batch without its cover, inserts the photos, sets the cover, and applies any share list.
 */
export async function createBatch({
  ownerID,
  title,
  description,
  place,
  frame,
  font,
  background,
  visibility = 'private',
  members = [],
  preparedPhotos,
  onProgress,
}) {
  if (!preparedPhotos?.length) throw new Error('Choose at least one photo to make a batch.')
  const batchID = crypto.randomUUID().toLowerCase()
  const { ready, uploadedPaths } = await prepareAndPublishAll(ownerID, preparedPhotos, onProgress)

  const dates = ready.map((p) => p.captured_at).filter(Boolean).sort()
  const shotOn = dates[0] ?? new Date().toISOString()
  const resolvedFrame = { ...defaultFrame, ...(frame || {}) }
  if (background) resolvedFrame.wall = legacyWallFor(background)

  const collectionRow = {
    id: batchID,
    owner_id: ownerID,
    title: (title || '').trim().slice(0, 120) || 'Untitled batch',
    place: place?.trim() ? place.trim().slice(0, 120) : null,
    shot_on: shotOn,
    cover_photo_id: null,
    frame: resolvedFrame,
    visibility,
  }
  if (description?.trim()) collectionRow.description = description.trim().slice(0, 280)
  if (font) collectionRow.font = font
  if (background) collectionRow.background = background

  try {
    check(await supabase.from('collections').insert(collectionRow))
    const photoRows = ready.map((p, index) => ({
      ...p,
      collection_id: batchID,
      sort_index: index,
      added_by: null,
    }))
    check(await supabase.from('photos').insert(photoRows))
    check(await supabase.from('collections').update({ cover_photo_id: photoRows[0].id }).eq('id', batchID))

    const keptMembers = (visibility === 'people' || visibility === 'followers') ? members : []
    if (keptMembers.length) {
      check(await supabase.from('collection_members').insert(
        keptMembers.map((m) => ({
          collection_id: batchID,
          user_id: m.id,
          can_add: !!m.can_add,
        })),
      ))
    }
    return batchID
  } catch (err) {
    await supabase.from('collections').delete().eq('id', batchID).catch(() => {})
    const keys = uploadedPaths.flatMap(objectPaths)
    if (keys.length) await supabase.storage.from('media').remove(keys).catch(() => {})
    throw err
  }
}

/**
 * Appends photos to an existing batch as either its owner (`added_by: null`) or an invited group
 * contributor (`added_by: me`), matching AppModel.addPhotos / AppModel.contribute on iOS.
 */
export async function addPhotosToBatch({
  batchID,
  me,
  isOwner,
  existingPhotos = [],
  coverPhotoID = null,
  preparedPhotos,
  onProgress,
}) {
  if (!preparedPhotos?.length) return batch(batchID)
  const startSort = existingPhotos.reduce((max, p) => Math.max(max, p.sort_index ?? -1), -1) + 1
  const { ready, uploadedPaths } = await prepareAndPublishAll(me, preparedPhotos, onProgress)
  try {
    const photoRows = ready.map((p, index) => ({
      ...p,
      collection_id: batchID,
      sort_index: startSort + index,
      added_by: isOwner ? null : me,
    }))
    check(await supabase.from('photos').insert(photoRows))
    if (isOwner && !coverPhotoID && photoRows.length) {
      check(await supabase.from('collections').update({ cover_photo_id: photoRows[0].id }).eq('id', batchID))
    }
    return batch(batchID)
  } catch (err) {
    const keys = uploadedPaths.flatMap(objectPaths)
    if (keys.length) await supabase.storage.from('media').remove(keys).catch(() => {})
    throw err
  }
}

export async function updateBatch(batchID, patch) {
  const row = {}
  if ('title' in patch) {
    const t = (patch.title || '').trim().slice(0, 120)
    if (t) row.title = t
  }
  if ('description' in patch) row.description = (patch.description || '').trim().slice(0, 280)
  if ('place' in patch) row.place = patch.place?.trim() ? patch.place.trim().slice(0, 120) : null
  if ('font' in patch) row.font = patch.font || null
  if ('background' in patch) row.background = patch.background || null
  if ('frame' in patch) row.frame = patch.frame
  if ('cover_photo_id' in patch) row.cover_photo_id = patch.cover_photo_id
  if ('visibility' in patch) row.visibility = patch.visibility
  if (Object.keys(row).length) {
    check(await supabase.from('collections').update(row).eq('id', batchID))
  }
}

export async function batchMembers(batchID) {
  const rows = check(await supabase.from('collection_members')
    .select('user_id, can_add, user:profiles!user_id(*)')
    .eq('collection_id', batchID))
  return rows.filter((r) => r.user).map((r) => ({ ...r.user, can_add: r.can_add === true }))
}

export async function setBatchSharing(batchID, visibility, members = []) {
  const kept = (visibility === 'people' || visibility === 'followers') ? members : []
  check(await supabase.from('collection_members').delete().eq('collection_id', batchID))
  if (kept.length) {
    check(await supabase.from('collection_members').insert(
      kept.map((m) => ({ collection_id: batchID, user_id: m.id, can_add: !!m.can_add })),
    ))
  }
  check(await supabase.from('collections').update({ visibility }).eq('id', batchID))
}

export async function removePhotoFromBatch({ batch: currentBatch, photo, isOwner }) {
  // Remove copies first while the photo row still grants storage delete to the batch owner.
  if (photo.share_path) {
    await supabase.storage.from('media').remove(objectPaths(photo.share_path)).catch(() => {})
  }
  check(await supabase.from('photos').delete().eq('id', photo.id).eq('collection_id', currentBatch.id))
  if (isOwner && currentBatch.cover_photo_id === photo.id) {
    const remaining = currentBatch.photos.filter((p) => p.id !== photo.id)
    const nextCover = remaining[0]?.id ?? null
    check(await supabase.from('collections').update({ cover_photo_id: nextCover }).eq('id', currentBatch.id))
  }
}

export async function deleteBatch(batchID) {
  const rows = check(await supabase.from('photos').select('share_path').eq('collection_id', batchID))
  check(await supabase.from('collections').delete().eq('id', batchID))
  const keys = rows.map((r) => r.share_path).filter(Boolean).flatMap(objectPaths)
  for (let i = 0; i < keys.length; i += 900) {
    await supabase.storage.from('media').remove(keys.slice(i, i + 900)).catch(() => {})
  }
}

// Books ------------------------------------------------------------------------------------------

const bookColumns = 'id, title, format, doc, revision, status, created_at, updated_at'

export async function books() {
  return check(await supabase.from('books').select(bookColumns).order('updated_at', { ascending: false }))
}

export async function book(id) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return null
  return check(await supabase.from('books').select(bookColumns).eq('id', id).maybeSingle())
}

export async function createBook({ title, format, doc, batchIDs }) {
  const id = crypto.randomUUID()
  check(await supabase.from('books').insert({ id, title, format, doc }))
  await setBookBatches(id, batchIDs)
  return id
}

/** Thrown when someone saved the book elsewhere since this copy was loaded. */
export class BookConflict extends Error {}

/** Saves only over the revision this copy was loaded at, and returns the new one. */
export async function saveBook(id, { title, doc }, revision) {
  const row = check(await supabase.from('books').update({ title, doc }).eq('id', id).eq('revision', revision).select('revision').maybeSingle())
  if (!row) throw new BookConflict('This book was changed somewhere else.')
  return row.revision
}

/** Saves whatever revision is there now: for "keep mine" after a conflict. */
export async function overwriteBook(id, { title, doc }) {
  return check(await supabase.from('books').update({ title, doc }).eq('id', id).select('revision').single()).revision
}

export async function deleteBook(id) {
  check(await supabase.from('books').delete().eq('id', id))
}

/** Which batches a book draws on, in chapter order. */
export async function setBookBatches(bookID, batchIDs) {
  const ids = [...new Set(batchIDs)]
  const current = check(await supabase.from('book_batches').select('collection_id, position').eq('book_id', bookID))
  const gone = current.map((r) => r.collection_id).filter((id) => !ids.includes(id))
  if (gone.length) check(await supabase.from('book_batches').delete().eq('book_id', bookID).in('collection_id', gone))
  const have = new Map(current.map((r) => [r.collection_id, r.position]))
  const fresh = ids.map((id, position) => ({ book_id: bookID, collection_id: id, position })).filter((r) => !have.has(r.collection_id))
  if (fresh.length) check(await supabase.from('book_batches').insert(fresh))
  for (const [position, id] of ids.entries()) {
    if (have.has(id) && have.get(id) !== position) check(await supabase.from('book_batches').update({ position }).eq('book_id', bookID).eq('collection_id', id))
  }
}

export async function bookBatchIDs(bookID) {
  return check(await supabase.from('book_batches').select('collection_id').eq('book_id', bookID).order('position')).map((r) => r.collection_id)
}

/** Print files go in the private prints bucket under your own folder. */
export async function uploadPrint(path, blob) {
  check(await supabase.storage.from('prints').upload(path, blob, { contentType: 'application/pdf', upsert: true }))
}

export async function printLink(path) {
  return check(await supabase.storage.from('prints').createSignedUrl(path, 3600)).signedUrl
}

/**
 * Gelato's cover measurements (millimetres) for a book with this many pages, from the print-cover
 * function, or null when printing isn't set up yet and the cover has to be estimated.
 */
export async function coverDimensions(pages) {
  try {
    const { data, error } = await supabase.functions.invoke('print-cover', { body: { pages } })
    return error ? null : data?.dimensions ?? null
  } catch { return null }
}

/** `printPath` is the one PDF Gelato prints from: cover sheet, endpaper, pages, last page. */
export async function orderBook({ bookID, revision, quantity, printPath, pageCount }) {
  const id = crypto.randomUUID()
  check(await supabase.from('book_orders').insert({
    id, book_id: bookID, book_revision: revision, quantity, print_path: printPath, page_count: pageCount,
  }))
  return id
}

export async function ordersOf(bookID) {
  return check(await supabase.from('book_orders').select().eq('book_id', bookID).order('created_at', { ascending: false }))
}

// Likes, comments, tags and notifications --------------------------------------------------------

/** Like, comment and tag data by photo. Row level security leaves out people across a block. */
export async function reactions(photoIDs, me) {
  const result = Object.fromEntries(photoIDs.map((id) => [id, { likes: 0, liked: false, comments: 0, tags: [] }]))
  if (!photoIDs.length) return result
  for (let i = 0; i < photoIDs.length; i += 100) {
    const ids = photoIDs.slice(i, i + 100)
    const [likes, comments, tags] = await Promise.all([
      supabase.from('photo_likes').select('photo_id, user_id').in('photo_id', ids).then(check),
      supabase.from('photo_comments').select('photo_id').in('photo_id', ids).then(check),
      supabase.from('photo_tags').select('photo_id, user_id, tagged_by, x, y, created_at, user:profiles!user_id(*)').in('photo_id', ids).order('created_at').then(check).catch(() => []),
    ])
    for (const l of likes) {
      result[l.photo_id].likes++
      if (l.user_id === me) result[l.photo_id].liked = true
    }
    for (const c of comments) result[c.photo_id].comments++
    for (const t of tags) result[t.photo_id]?.tags.push(t)
  }
  return result
}

export async function canAddToBatch(batchID, me) {
  const rows = check(await supabase.from('collection_members')
    .select('can_add').eq('collection_id', batchID).eq('user_id', me).limit(1))
  return rows[0]?.can_add === true
}

export async function setTag({ photoID, userID, x = null, y = null, me }) {
  return check(await supabase.from('photo_tags')
    .upsert({ photo_id: photoID, user_id: userID, tagged_by: me, x, y })
    .select('photo_id, user_id, tagged_by, x, y, created_at, user:profiles!user_id(*)')
    .single())
}

export async function removeTag(photoID, userID) {
  check(await supabase.from('photo_tags').delete().eq('photo_id', photoID).eq('user_id', userID))
}

export async function taggedBatchesOf(userID) {
  const tagRows = await supabase.from('photo_tags')
    .select('photo:photos!photo_id(collection_id)')
    .eq('user_id', userID)
    .order('created_at', { ascending: false })
    .limit(200)
    .then(check)
    .catch(() => [])
  const ids = [...new Set(tagRows.map((r) => r.photo?.collection_id).filter(Boolean))]
  if (!ids.length) return []
  const rows = check(await supabase.from('collections').select(batchSelect)
    .in('id', ids).order('shot_on', { ascending: false, nullsFirst: false }))
  return finish(rows)
}

export async function notifications(me, limit = 80) {
  return supabase.from('notifications')
    .select('id, recipient_id, actor_id, kind, collection_id, photo_id, comment_id, body, read_at, created_at, actor:profiles!actor_id(*), collection:collections!collection_id(title), photo:photos!photo_id(id, pixel_width, pixel_height, share_path)')
    .eq('recipient_id', me)
    .order('created_at', { ascending: false })
    .limit(limit)
    .then(check)
    .catch(() => [])
}

export async function markNotificationsRead(ids) {
  const valid = ids.filter((id) => /^[0-9a-f-]{36}$/i.test(id))
  if (!valid.length) return
  await supabase.from('notifications')
    .update({ read_at: new Date().toISOString() })
    .in('id', valid)
    .is('read_at', null)
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

// Classify Mattermost WebSocket `posted` events into connector inbound kinds.
// Pure module — no I/O, no deps. All lookups are injected via ClassifyCtx.

export type Post = {
  id: string
  channel_id: string
  root_id: string
  user_id: string
  message: string
  type: string
  create_at: number
  file_ids: string[]
}

export type PostedData = {
  channel_type: string // 'D' | 'O' | 'P' | 'G'
  channel_name: string
  channel_display_name: string
  team_id: string
  sender_name: string
  mentions: string[] // user ids
}

export type Parsed = { post: Post; data: PostedData }

export type InboundKind = 'dm' | 'thread' | 'mention'

export type Inbound = Parsed & {
  kind: InboundKind
  /** root_id Claude must pass back to `reply` so the answer lands in the right place ('' = plain post). */
  reply_root_id: string
}

export type ClassifyCtx = {
  botUserId: string
  botUsername: string
  /** true if the thread root post was authored by the bot (may hit the API). */
  isBotThreadRoot: (rootId: string) => boolean | Promise<boolean>
  /** true if the bot has already replied in this thread during this session. */
  isEngagedThread: (rootId: string) => boolean
}

function parseMaybeJson<T>(value: unknown, fallback: T): T {
  if (value == null) return fallback
  if (typeof value !== 'string') return value as T
  try {
    return JSON.parse(value) as T
  } catch {
    return fallback
  }
}

/** Returns null for anything that is not a user-authored `posted` event. */
export function parsePostedEvent(ev: unknown): Parsed | null {
  if (!ev || typeof ev !== 'object') return null
  const e = ev as { event?: unknown; data?: Record<string, unknown> }
  if (e.event !== 'posted' || !e.data) return null
  // Mattermost serialises `post` and `mentions` as JSON *strings* inside the event data.
  const rawPost = parseMaybeJson<Record<string, unknown> | null>(e.data.post, null)
  if (!rawPost || typeof rawPost.id !== 'string') return null
  const post: Post = {
    id: rawPost.id,
    channel_id: String(rawPost.channel_id ?? ''),
    root_id: String(rawPost.root_id ?? ''),
    user_id: String(rawPost.user_id ?? ''),
    message: String(rawPost.message ?? ''),
    type: String(rawPost.type ?? ''),
    create_at: Number(rawPost.create_at ?? 0),
    file_ids: Array.isArray(rawPost.file_ids) ? rawPost.file_ids.map(String) : [],
  }
  if (post.type !== '') return null // system_join_channel, system_header_change, ...
  const mentions = parseMaybeJson<unknown>(e.data.mentions, [])
  const data: PostedData = {
    channel_type: String(e.data.channel_type ?? ''),
    channel_name: String(e.data.channel_name ?? ''),
    channel_display_name: String(e.data.channel_display_name ?? ''),
    team_id: String(e.data.team_id ?? ''),
    sender_name: String(e.data.sender_name ?? ''),
    mentions: Array.isArray(mentions) ? mentions.map(String) : [],
  }
  return { post, data }
}

export function mentionsBot(text: string, botUsername: string): boolean {
  if (!botUsername) return false
  const escaped = botUsername.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(^|[\\s(\\[])@${escaped}(?![\\w.-])`, 'i').test(text)
}

/**
 * Precedence: own post → null; DM → dm; reply in bot/engaged thread → thread;
 * @mention → mention (threaded under the triggering post); otherwise null.
 */
export async function classify(parsed: Parsed, ctx: ClassifyCtx): Promise<Inbound | null> {
  const { post, data } = parsed
  if (post.user_id === ctx.botUserId) return null
  if (data.channel_type === 'D') {
    return { ...parsed, kind: 'dm', reply_root_id: post.root_id || '' }
  }
  if (post.root_id) {
    const engaged = ctx.isEngagedThread(post.root_id) || (await ctx.isBotThreadRoot(post.root_id))
    if (engaged) return { ...parsed, kind: 'thread', reply_root_id: post.root_id }
  }
  if (data.mentions.includes(ctx.botUserId) || mentionsBot(post.message, ctx.botUsername)) {
    return { ...parsed, kind: 'mention', reply_root_id: post.root_id || post.id }
  }
  return null
}

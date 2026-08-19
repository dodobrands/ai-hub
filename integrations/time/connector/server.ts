#!/usr/bin/env bun
// Claude Code Channel connector for Time (Mattermost).
//
//   server.ts serve   — MCP stdio server (launched by Claude Code via .mcp.json / `claude mcp add`)
//   server.ts check   — REST-only preflight: bot identity, whitelist resolution, teams. No MCP.
//
// Start through scripts/time-connector.sh — it loads .env (TIME_BOT_TOKEN, TIME_BASE_URL) and
// exports TIME_TEAM_CONFIG. Docs: integrations/time/README.md, section "Connector".
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { z } from 'zod'
import { loadConfig, type Config } from './src/config.ts'
import { MattermostRest, MattermostWs, MattermostApiError, type MmUser, type MmTeam } from './src/mattermost.ts'
import { classify, parsePostedEvent, type Inbound } from './src/classify.ts'
import { chunk } from './src/chunk.ts'
import { buildInstructions } from './src/instructions.ts'

const VERSION = '1.0.0'
const MODE = process.argv[2] ?? 'serve'

function log(msg: string): void {
  process.stderr.write(`time-connector: ${msg}\n`)
}

process.on('unhandledRejection', err => log(`unhandled rejection: ${err}`))
process.on('uncaughtException', err => log(`uncaught exception: ${err}`))

let cfg: Config
try {
  cfg = loadConfig()
} catch (e) {
  log(String((e as Error).message ?? e))
  process.exit(1)
}

const api = new MattermostRest(cfg.baseUrl, cfg.token)

// ---------------------------------------------------------------- state

let me: MmUser = { id: '', username: '' }
let defaultTeam: MmTeam | null = null
/** username → user id for the whitelist; refreshed periodically. */
let allowedIds = new Map<string, string>()
let unresolvedUsers: string[] = []
/** channel ids we have received an allowed inbound from (or relay DMs) — outbound gate for `reply`. */
const knownChannels = new Set<string>()
/** thread roots where the bot has posted in this session → follow-ups are delivered without @mention. */
const engagedThreads = new Set<string>()
/** thread root id → author id (bounded LRU-ish cache). */
const rootAuthors = new Map<string, string>()
const ROOT_CACHE_MAX = 5000
/** last sender we delivered to — permission prompts are relayed to their DM. */
let lastActive: { user_id: string; username: string; dm_channel_id?: string } | null = null

const PERMISSION_REPLY_RE = /^\s*(y|yes|n|no)\s+([a-km-z]{5})\s*$/i
const pendingPermissions = new Map<string, { tool_name: string; description: string; input_preview: string }>()

function safeName(s: string): string {
  return s.replace(/[<>"\r\n]/g, '').slice(0, 128)
}

function rememberRoot(rootId: string, authorId: string): void {
  if (rootAuthors.size >= ROOT_CACHE_MAX) {
    const first = rootAuthors.keys().next().value
    if (first !== undefined) rootAuthors.delete(first)
  }
  rootAuthors.set(rootId, authorId)
}

async function isBotThreadRoot(rootId: string): Promise<boolean> {
  const cached = rootAuthors.get(rootId)
  if (cached !== undefined) return cached === me.id
  try {
    const root = await api.getPost(rootId)
    rememberRoot(rootId, root.user_id)
    return root.user_id === me.id
  } catch (e) {
    log(`cannot fetch thread root ${rootId}: ${e}`)
    return false
  }
}

async function resolveWhitelist(): Promise<void> {
  const names = cfg.whitelist.users
  if (!names.length) {
    allowedIds = new Map()
    unresolvedUsers = []
    return
  }
  try {
    const users = await api.getUsersByUsernames(names)
    const next = new Map<string, string>()
    for (const u of users) next.set(u.username.toLowerCase(), u.id)
    allowedIds = next
    unresolvedUsers = names.filter(n => !next.has(n))
    if (unresolvedUsers.length) log(`whitelist: unresolved usernames (typo? not in this Time?): ${unresolvedUsers.join(', ')}`)
  } catch (e) {
    log(`whitelist: resolve failed (${e}); keeping previous ${allowedIds.size} id(s)`)
  }
}

function isAllowedSender(userId: string): boolean {
  for (const id of allowedIds.values()) if (id === userId) return true
  return false
}

async function bootstrap(): Promise<void> {
  me = await api.me()
  try {
    const teams = await api.myTeams()
    defaultTeam = teams[0] ?? null
  } catch (e) {
    log(`cannot list bot teams: ${e}`)
  }
  await resolveWhitelist()
}

async function permalink(postId: string, teamId: string): Promise<string> {
  const team = (teamId ? await api.getTeam(teamId) : null) ?? defaultTeam
  return team ? `${cfg.baseUrl}/${team.name}/pl/${postId}` : ''
}

// ---------------------------------------------------------------- check mode

async function runCheck(): Promise<never> {
  const out = (s: string) => process.stdout.write(s + '\n')
  let ok = true
  try {
    await bootstrap()
  } catch (e) {
    if (e instanceof MattermostApiError && e.status === 401) {
      out(`error:token_invalid  ${cfg.baseUrl} rejected TIME_BOT_TOKEN (HTTP 401)`)
    } else {
      out(`error:connect  ${cfg.baseUrl}: ${e}`)
    }
    process.exit(1)
  }
  out(`bot:        @${me.username} (${me.id})${me.is_bot ? '' : '  ⚠ this token belongs to a regular user, not a bot account'}`)
  out(`base_url:   ${cfg.baseUrl}`)
  out(`team_config:${cfg.teamConfigPath ? ' ' + cfg.teamConfigPath : ' (none)'}`)
  out(`whitelist:  source=${cfg.whitelist.source}`)
  if (!cfg.whitelist.users.length) {
    out('  ⚠ whitelist is EMPTY — every inbound message will be dropped. Set time.connector.allowed_users in team-config.json or TIME_CONNECTOR_ALLOWED_USERS in .env')
    ok = false
  }
  for (const n of cfg.whitelist.users) out(`  ${allowedIds.has(n) ? '✓' : '✗'} ${n}${allowedIds.has(n) ? '' : '  (not found)'}`)
  try {
    const teams = await api.myTeams()
    out(`teams:      ${teams.length ? teams.map(t => t.name).join(', ') : '(none — bot is not a member of any team; @mentions in channels will not arrive)'}`)
  } catch {}
  out('note:       the bot only receives channel posts where it is a member (/invite @' + me.username + '); DMs work without invites.')
  out(ok ? 'STATUS: OK' : 'STATUS: WARN')
  process.exit(0)
}

if (MODE === 'check') await runCheck()
if (MODE !== 'serve') {
  log(`unknown mode "${MODE}" (expected serve|check)`)
  process.exit(2)
}

// ---------------------------------------------------------------- MCP server

// Try to learn the bot identity before the MCP handshake so `instructions` can name it;
// if Time is unreachable we still start (tools error, bootstrap retries below).
let bootstrapped = false
try {
  await Promise.race([
    bootstrap().then(() => { bootstrapped = true }),
    new Promise<void>((_, rej) => setTimeout(() => rej(new Error('timeout 8s')), 8000).unref?.()),
  ])
} catch (e) {
  log(`initial bootstrap failed: ${e}`)
}

const mcp = new Server(
  { name: cfg.serverName, version: VERSION },
  {
    capabilities: {
      tools: {},
      experimental: {
        'claude/channel': {},
        // Permission relay: we authenticate repliers (whitelist by user id, and only the
        // last active sender may answer), so declaring this is legitimate.
        'claude/channel/permission': {},
      },
    },
    instructions: buildInstructions(me.username || 'bot'),
  },
)

// Permission requests from Claude Code → DM of the last active sender (never into channels/threads).
mcp.setNotificationHandler(
  z.object({
    method: z.literal('notifications/claude/channel/permission_request'),
    params: z.object({
      request_id: z.string(),
      tool_name: z.string(),
      description: z.string(),
      input_preview: z.string(),
    }),
  }),
  async ({ params }) => {
    const { request_id, tool_name, description, input_preview } = params
    pendingPermissions.set(request_id, { tool_name, description, input_preview })
    if (!lastActive) {
      log(`permission_request ${request_id} (${tool_name}): no active Time sender — approve in the terminal`)
      return
    }
    try {
      if (!lastActive.dm_channel_id) {
        const dm = await api.createDirectChannel(me.id, lastActive.user_id)
        lastActive.dm_channel_id = dm.id
      }
      knownChannels.add(lastActive.dm_channel_id)
      const preview = input_preview.length > 1500 ? input_preview.slice(0, 1500) + '…' : input_preview
      const text = [
        `🔐 Claude просит разрешение: **${tool_name}**`,
        description ? description : '',
        '```',
        preview,
        '```',
        `Ответь в этом чате \`yes ${request_id}\` или \`no ${request_id}\`.`,
      ]
        .filter(Boolean)
        .join('\n')
      await api.createPost({ channel_id: lastActive.dm_channel_id, message: text })
    } catch (e) {
      log(`permission_request ${request_id}: DM to @${lastActive.username} failed: ${e}`)
    }
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description:
        'Send a message to Time (Mattermost). Pass channel_id from the inbound <channel> tag. Pass root_id (from the tag) whenever it is non-empty so the answer stays in that thread; omit it for plain DMs. Mattermost markdown is supported; long text is split into several posts automatically.',
      inputSchema: {
        type: 'object',
        properties: {
          channel_id: { type: 'string', description: 'channel_id from the inbound tag' },
          text: { type: 'string', description: 'Message text (Mattermost markdown)' },
          root_id: { type: 'string', description: 'Thread root id — the root_id attribute of the inbound tag. Empty/omitted = post without a thread.' },
        },
        required: ['channel_id', 'text'],
      },
    },
    {
      name: 'react',
      description: 'Add an emoji reaction to a Time post (e.g. white_check_mark, eyes, +1). Use post_id from the inbound tag.',
      inputSchema: {
        type: 'object',
        properties: {
          post_id: { type: 'string' },
          emoji: { type: 'string', description: 'Emoji name without colons, e.g. white_check_mark' },
        },
        required: ['post_id', 'emoji'],
      },
    },
  ],
}))

function assertKnownChannel(channel_id: string): void {
  if (!knownChannels.has(channel_id)) {
    throw new Error(
      `channel ${channel_id} is not one this connector received a whitelisted message from in this session. ` +
        'Reply only to the channel_id from the inbound tag; for arbitrary posting use integrations/time/scripts/time-messages.sh.',
    )
  }
}

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  try {
    switch (req.params.name) {
      case 'reply': {
        const channel_id = String(args.channel_id ?? '')
        const text = String(args.text ?? '')
        const root_id = String(args.root_id ?? '')
        if (!channel_id || !text) throw new Error('channel_id and text are required')
        assertKnownChannel(channel_id)
        const parts = chunk(text, cfg.chunkLimit, 'newline')
        const ids: string[] = []
        let teamId = ''
        for (const part of parts) {
          try {
            const post = await api.createPost({ channel_id, message: part, root_id })
            ids.push(post.id)
          } catch (e) {
            throw new Error(`reply failed after ${ids.length} of ${parts.length} part(s) sent: ${e}`)
          }
        }
        const threadRoot = root_id || ids[0]!
        engagedThreads.add(threadRoot)
        rememberRoot(threadRoot, root_id ? rootAuthors.get(root_id) ?? '' : me.id)
        try {
          const ch = await api.getChannel(channel_id)
          teamId = ch.team_id
        } catch {}
        const link = await permalink(ids[0]!, teamId)
        const summary = ids.length === 1 ? `sent (post_id: ${ids[0]})` : `sent ${ids.length} parts (post_ids: ${ids.join(', ')})`
        return { content: [{ type: 'text', text: link ? `${summary} ${link}` : summary }] }
      }
      case 'react': {
        const post_id = String(args.post_id ?? '')
        const emoji = String(args.emoji ?? '').replace(/^:|:$/g, '')
        if (!post_id || !emoji) throw new Error('post_id and emoji are required')
        await api.addReaction({ user_id: me.id, post_id, emoji_name: emoji })
        return { content: [{ type: 'text', text: `reacted :${emoji}:` }] }
      }
      default:
        throw new Error(`unknown tool ${req.params.name}`)
    }
  } catch (e) {
    return { content: [{ type: 'text', text: `${req.params.name} failed: ${(e as Error).message ?? e}` }], isError: true }
  }
})

// ---------------------------------------------------------------- inbound

async function handleInbound(inb: Inbound, sender: MmUser): Promise<void> {
  const { post, data } = inb
  knownChannels.add(post.channel_id)
  if (inb.kind === 'dm') lastActive = { user_id: sender.id, username: sender.username, dm_channel_id: post.channel_id }
  else lastActive = { user_id: sender.id, username: sender.username, dm_channel_id: lastActive?.user_id === sender.id ? lastActive.dm_channel_id : undefined }

  ws.typing(post.channel_id, inb.reply_root_id)
  if (cfg.ackReaction) void api.addReaction({ user_id: me.id, post_id: post.id, emoji_name: cfg.ackReaction }).catch(() => {})

  const link = await permalink(post.id, data.team_id)
  const team = data.team_id ? await api.getTeam(data.team_id) : defaultTeam
  const meta: Record<string, string> = {
    source: 'time',
    kind: inb.kind,
    post_id: post.id,
    channel_id: post.channel_id,
    root_id: inb.reply_root_id,
    user: safeName(sender.username),
    user_id: sender.id,
    team: safeName(team?.name ?? ''),
    channel: data.channel_type === 'D' ? 'DM' : safeName(data.channel_name),
    permalink: link,
    ts: new Date(post.create_at || Date.now()).toISOString(),
  }
  if (post.file_ids.length) meta.file_count = String(post.file_ids.length)

  log(`← ${inb.kind} from @${sender.username} in ${meta.channel} (${post.id})`)
  await mcp.notification({ method: 'notifications/claude/channel', params: { content: post.message, meta } }).catch(e => {
    log(`failed to deliver inbound to Claude: ${e}`)
  })
}

async function onWsEvent(ev: unknown): Promise<void> {
  const parsed = parsePostedEvent(ev)
  if (!parsed) return
  const { post, data } = parsed
  if (post.user_id === me.id) {
    // Remember threads the bot starts via other tools (e.g. time-messages.sh --as bot send).
    if (!post.root_id) rememberRoot(post.id, me.id)
    return
  }
  if (!isAllowedSender(post.user_id)) {
    log(`drop: ${data.sender_name || post.user_id} not in whitelist (${data.channel_type === 'D' ? 'DM' : data.channel_name})`)
    return
  }
  const sender = (await api.getUser(post.user_id)) ?? { id: post.user_id, username: data.sender_name.replace(/^@/, '') || post.user_id }
  if (cfg.ignoreBots && sender.is_bot) {
    log(`drop: @${sender.username} is a bot`)
    return
  }

  // Permission reply intercept — DM only, only from the sender we relayed to.
  if (data.channel_type === 'D') {
    const m = PERMISSION_REPLY_RE.exec(post.message)
    if (m) {
      const request_id = m[2]!.toLowerCase()
      const allow = m[1]!.toLowerCase().startsWith('y')
      if (!lastActive || lastActive.user_id !== sender.id) {
        log(`permission reply from @${sender.username} ignored (not the active sender)`)
        return
      }
      pendingPermissions.delete(request_id)
      void mcp.notification({
        method: 'notifications/claude/channel/permission',
        params: { request_id, behavior: allow ? 'allow' : 'deny' },
      }).catch(e => log(`permission reply relay failed: ${e}`))
      void api.addReaction({ user_id: me.id, post_id: post.id, emoji_name: allow ? 'white_check_mark' : 'x' }).catch(() => {})
      return
    }
  }

  const inb = await classify(parsed, {
    botUserId: me.id,
    botUsername: me.username,
    isBotThreadRoot,
    isEngagedThread: id => engagedThreads.has(id),
  })
  if (!inb) return
  await handleInbound(inb, sender)
}

const ws = new MattermostWs(cfg.baseUrl, cfg.token, {
  log,
  onEvent: ev => void onWsEvent(ev).catch(e => log(`inbound error: ${e}`)),
})

await mcp.connect(new StdioServerTransport())

function announce(): void {
  log(`bot @${me.username}, whitelist ${allowedIds.size}/${cfg.whitelist.users.length} resolved (source=${cfg.whitelist.source})${cfg.whitelist.users.length ? '' : ' — EMPTY, all inbound will be dropped'}`)
}

if (bootstrapped) {
  announce()
  ws.connect()
} else {
  // Keep serving (tools will error) and keep retrying the bootstrap so a fixed token/network recovers.
  const retry = setInterval(async () => {
    try {
      await bootstrap()
      clearInterval(retry)
      announce()
      ws.connect()
    } catch (err) {
      log(`bootstrap retry failed: ${err}`)
    }
  }, 30000)
  retry.unref?.()
}
setInterval(() => void resolveWhitelist(), 10 * 60 * 1000).unref?.()

// ---------------------------------------------------------------- shutdown

let shuttingDown = false
function shutdown(): void {
  if (shuttingDown) return
  shuttingDown = true
  log('shutting down')
  ws.close()
  setTimeout(() => process.exit(0), 2000).unref?.()
  void Promise.resolve(mcp.close()).finally(() => process.exit(0))
}
process.stdin.on('end', shutdown)
process.stdin.on('close', shutdown)
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
process.on('SIGHUP', shutdown)
setInterval(() => {
  if (process.stdin.destroyed || process.stdin.readableEnded) shutdown()
}, 5000).unref()

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BackgroundTask } from '../types'

// The status lives in the title icon. Two options (userConfig) shape the sidebar:
// openSection — the section a session moves to when the person writes in it
// (empty: never move); keepPrefix — sections whose name starts with it are never left.
type Options = { openSection?: string; keepPrefix?: string }
let options: Options = {}
type Status = 'working' | 'running' | 'ask' | 'done' | 'failed'
const ICON: Record<Status, string> = { working: '🔄', running: '⏳', ask: '⚠️', done: '✅', failed: '❌' }
const ICON_RE = /^(?:🔄|⏳|⚠️|⚠|✅|❌)\s*/u

// The icon this session shows now; the band above the prompt offers to clear ✅.
const shown = atom({ plugin: 'agent-status', key: 'shown' } as const, null)
// Background work this session started and has not heard back from yet, shown
// above the prompt. classic.Stop, which reports it exactly, does not reach a
// plugin a person installs where the organization manages Claude Code.
const tasks = atom({ plugin: 'agent-status', key: 'tasks' } as const, [])
const isExpanded = atom({ plugin: 'agent-status', key: 'isExpanded' } as const, false)
const now = atom({ plugin: 'agent-status', key: 'now' } as const, 0)
const FOLDED_ROWS = 3
const ENDED = /<status>\s*(completed|failed|killed|stopped|timed_out|error)\s*<\/status>/i

// A link to what a background command waits for, where the command names it:
// a Databricks job run (host from ~/.databrickscfg by --profile) or a GitHub Actions run.
type RunLink = { href: string; label: string }
let databricksHosts: Record<string, string> | undefined
let databricksDefault = ''
async function loadDatabricksHosts($: EngineInterface): Promise<Record<string, string>> {
  if (databricksHosts) return databricksHosts
  databricksHosts = {}
  let text = ''
  try {
    text = await $.fs.read(`${(await $.env.get('HOME')) ?? '.'}/.databrickscfg`)
  } catch {}
  let section = ''
  for (const line of text.split('\n')) {
    const head = /^\s*\[([^\]]+)\]/.exec(line)
    if (head) {
      section = head[1] ?? ''
      continue
    }
    const kv = /^\s*(host|default_profile)\s*=\s*(\S+)/.exec(line)
    if (!kv) continue
    if (kv[1] === 'host') databricksHosts[section] = (kv[2] ?? '').replace(/\/+$/, '')
    else databricksDefault = kv[2] ?? ''
  }
  return databricksHosts
}

async function linkFor($: EngineInterface, command: string): Promise<RunLink | undefined> {
  const gh = /gh\s+run\s+(?:watch|view)\s+(\d+)[^\n]*?--repo[= ](\S+)/.exec(command)
  if (gh) return { href: `https://github.com/${gh[2]}/actions/runs/${gh[1]}`, label: 'run ↗' }
  if (!/databricks/.test(command)) return undefined
  const run =
    /jobs\s+get-run(?:-output)?\s+(\d{6,})/.exec(command) ?? /--run[-_]id[= ](\d{6,})/.exec(command)
  if (!run) return undefined
  const hosts = await loadDatabricksHosts($)
  const profile = /(?:--profile|\s-p)[= ](\S+)/.exec(command)?.[1] ?? databricksDefault
  const host = hosts[profile] ?? Object.values(hosts)[0]
  if (!host) return undefined
  const workspace = /adb-(\d+)/.exec(host)?.[1]
  return { href: `${host}/jobs/runs/${run[1]}${workspace ? `?o=${workspace}` : ''}`, label: 'ноутбук ↗' }
}

function elapsed(ms: number): string {
  const min = Math.floor(ms / 60000)
  if (min < 1) return '<1 мин'
  if (min < 60) return `${min} мин`
  return `${Math.floor(min / 60)} ч ${min % 60} мин`
}

type Session = {
  sessionId: string
  title: string
  isRunning?: boolean
  pinned?: boolean
  group?: { id: string; name: string } | null
}

async function callJson($: EngineInterface, tool: string, input: object): Promise<any> {
  // Rejects while the app's MCP tools have not connected yet.
  const r = await $.tool.call({ tool, ...input } as any).catch(() => undefined)
  if (!r || r.deny !== undefined || r.isError || typeof r.text !== 'string') return undefined
  try {
    return JSON.parse(r.text)
  } catch {
    return undefined
  }
}

// The id of the section named by openSection, looked up once per load.
let openSectionId: string | null | undefined
async function openSection($: EngineInterface): Promise<string | null> {
  const name = (options.openSection ?? '').trim()
  if (name === '') return null
  if (openSectionId !== undefined) return openSectionId
  const sections: { id: string; name: string }[] | undefined = await callJson(
    $,
    'mcp__ccd_sidebar__list_sections',
    {},
  )
  if (!sections) return null
  openSectionId = sections.find(x => x.name === name)?.id ?? null
  return openSectionId
}

// Sets the title icon and, when asked, moves the session to the open section.
// A session in a keepPrefix section stays put; a title the app refused to change
// once is left alone.
async function apply($: EngineInterface, status: Status | null, toOpen: boolean) {
  const section = toOpen ? await openSection($) : null
  const me: Session | undefined = await callJson($, 'mcp__ccd_session_mgmt__get_session', {
    session_id: 'self',
  })
  if (!me) return

  await update($, shown, () => status)
  const base = me.title.replace(ICON_RE, '')
  const title = status ? `${ICON[status]} ${base}` : base
  const lockKey = `locked:${me.sessionId}`
  if (title !== me.title && !(await $.store.get(lockKey))) {
    const r = await $.tool.call({
      tool: 'mcp__ccd_session_mgmt__set_session_title',
      session_id: 'self',
      title,
    } as any)
    if (r.deny !== undefined || r.isError) await $.store.set(lockKey, true)
  }

  const keep = (options.keepPrefix ?? '').trim()
  const isPinned = me.pinned === true || (keep !== '' && (me.group?.name ?? '').startsWith(keep))
  if (section && !isPinned && me.group?.id !== section) {
    await $.tool.call({
      tool: 'mcp__ccd_sidebar__move_sessions',
      session_ids: ['self'],
      section_id: section,
    } as any)
  }
}

const CLASSIFY = `You label the final message of an AI agent's turn for a status icon.
Answer with exactly one word:
ASK  - the message asks the user something: a question, a decision, an approval, a clarification, or offers a next step and waits for a go-ahead;
FAIL - the work failed or is blocked and the agent cannot continue on its own;
DONE - the task is finished and nothing is asked of the user.
Message:
`

// Haiku spend, one file per session and day, so sessions never write the same
// file: ~/.claude/agent-status-usage/<date>/<session>.json. /agent-status-usage sums a day.
async function usageDir($: EngineInterface): Promise<string> {
  return `${(await $.env.get('HOME')) ?? '.'}/.claude/agent-status-usage`
}
type Usage = { calls: number; input: number; output: number; cacheRead: number }

async function today($: EngineInterface): Promise<string> {
  const d = new Date(await $.clock.now())
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

async function recordUsage(
  $: EngineInterface,
  u: { input_tokens: number; output_tokens: number; cache_read_input_tokens: number },
) {
  const path = `${await usageDir($)}/${await today($)}/${await $.session.id()}.json`
  let sum: Usage = { calls: 0, input: 0, output: 0, cacheRead: 0 }
  try {
    sum = JSON.parse(await $.fs.read(path)) as Usage
  } catch {}
  sum = {
    calls: sum.calls + 1,
    input: sum.input + u.input_tokens,
    output: sum.output + u.output_tokens,
    cacheRead: sum.cacheRead + u.cache_read_input_tokens,
  }
  await $.fs.write(path, JSON.stringify(sum))
}

async function usageReport($: EngineInterface): Promise<string> {
  const day = await today($)
  const dir = `${await usageDir($)}/${day}`
  const files = await $.fs.list(dir).catch(() => [])
  const total: Usage = { calls: 0, input: 0, output: 0, cacheRead: 0 }
  for (const f of files) {
    if (f.kind !== 'file') continue
    try {
      const u = JSON.parse(await $.fs.read(`${dir}/${f.name}`)) as Usage
      total.calls += u.calls
      total.input += u.input
      total.output += u.output
      total.cacheRead += u.cacheRead
    } catch {}
  }
  const fmt = (n: number) => n.toLocaleString('ru-RU')
  return `Haiku за ${day}: ${fmt(total.calls)} вызовов, ${fmt(total.input)} токенов на входе, ${fmt(total.output)} на выходе${total.cacheRead ? `, ${fmt(total.cacheRead)} из кеша` : ''}; сессий: ${files.length}.`
}

async function classify($: EngineInterface, message: string): Promise<Status> {
  const text = message.trim().slice(-2000)
  if (text === '') return 'done'
  const r = await $.model.complete({
    model: 'haiku',
    prompt: CLASSIFY + text,
    maxTokens: 5,
    timeoutMs: 15000,
  })
  await recordUsage($, r.usage).catch(() => {})
  const word = r.isAnswered ? r.text.trim().toUpperCase() : ''
  if (word.startsWith('ASK')) return 'ask'
  if (word.startsWith('FAIL')) return 'failed'
  if (word.startsWith('DONE')) return 'done'
  return /\?\s*$/.test(text) ? 'ask' : 'done'
}

// A session loaded with no icon (opened before the mod, or after a restart)
// takes one from its last answer. Background runs started before the load are
// not visible here, so such a session gets ⚠️/✅ rather than ⏳.
async function initIcon($: EngineInterface): Promise<string> {
  const me: Session | undefined = await callJson($, 'mcp__ccd_session_mgmt__get_session', {
    session_id: 'self',
  })
  if (!me) return 'retry: get_session unavailable'
  if (me.isRunning) return `${me.title}: running`
  const current = (Object.keys(ICON) as Status[]).find(k => me.title.startsWith(ICON[k]))
  // 🔄 left over from a turn a restart cut short is read again from the last answer.
  if (current && current !== 'working') {
    await update($, shown, () => current)
    return `${me.title}: has icon`
  }
  const messages = await $.session.messages()
  if (!Array.isArray(messages)) return `${me.title}: messages denied`
  const last = messages.at(-1)
  if (!last) return `${me.title}: no messages`
  if (last.role !== 'assistant' || last.text.trim() === '') return `${me.title}: last is ${last.role}`
  const status = await classify($, last.text)
  await apply($, status, false)
  return `${me.title}: set ${status}`
}

// The session's MCP tools connect after the mod loads: try again until they answer.
const INIT_WAITS = [3000, 10000, 20000, 30000, 60000]
function initWithRetry($: EngineInterface, attempt = 0) {
  $.clock.after(INIT_WAITS[attempt] ?? 60000, () => {
    void (async () => {
      let result: string
      try {
        result = await initIcon($)
      } catch (err) {
        result = `error: ${String(err)}`
      }
      if (result.startsWith('retry') && attempt + 1 < INIT_WAITS.length) initWithRetry($, attempt + 1)
    })()
  })
}

// The start-up icon pass runs once per load. /reload-plugins does not raise
// session.start again, so the first draw of the prompt starts it too.
let isInitStarted = false
function startInit($: EngineInterface) {
  if (isInitStarted) return
  isInitStarted = true
  initWithRetry($)
}

export const register: Register = (on, config) => {
  options = config as Options
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'agent-status-usage',
      description: 'Сколько токенов Haiku мод agent-status потратил сегодня',
    }).catch(() => {})
    startInit($)
    // The elapsed times above the prompt move on while any task runs.
    $.clock.every(30000, () => {
      void (async () => {
        if ((await read($, tasks)).length === 0) return
        const t = await $.clock.now()
        await update($, now, () => t)
      })().catch(() => {})
    })
    return next(e)
  })

  let answer = ''

  on('command.run', { command: 'agent-status-usage' }, async $ => ({ text: await usageReport($) })).catch(
    () => ({ text: 'Не удалось прочитать расход.' }),
  )

  on('tool.call', async ($, e, next) => {
    const input = e as {
      tool: string
      run_in_background?: boolean
      description?: string
      command?: string
      task_id?: string
      shell_id?: string
    }
    // A question or a plan waits for the person inside the tool, not in the
    // answer text Haiku reads: ⚠️ while it waits, 🔄 once answered.
    const isQuestion = input.tool === 'AskUserQuestion' || input.tool === 'ExitPlanMode'
    if (isQuestion) $.clock.after(0, () => void apply($, 'ask', false).catch(() => {}))
    const r = await next(e)
    if (isQuestion) $.clock.after(0, () => void apply($, 'working', false).catch(() => {}))
    if (r.deny !== undefined || r.isError) return r

    const out = (r.result ?? {}) as { backgroundTaskId?: string; taskId?: string; agentId?: string; status?: string }
    const id =
      input.tool === 'Bash'
        ? out.backgroundTaskId
        : input.tool === 'Monitor'
          ? out.taskId
          : input.tool === 'Agent' && input.run_in_background === true
            ? out.agentId
            : undefined
    if (id) {
      const link = await linkFor($, input.command ?? '').catch(() => undefined)
      const task: BackgroundTask = {
        id,
        kind: input.tool,
        label: input.description ?? (input.command ?? '').slice(0, 80),
        startedAt: await $.clock.now(),
        ...(link ? { link } : {}),
      }
      await update($, tasks, list => [...list.filter(t => t.id !== id), task])
      await update($, now, () => task.startedAt)
    }
    if (input.tool === 'TaskStop') {
      const stopped = input.task_id ?? input.shell_id
      await update($, tasks, list => list.filter(t => t.id !== stopped))
    }
    return r
  }).catch(($, e, next) => next(e))

  // The person wrote, or a background task reported: the session is in work again (🔄).
  on('prompt.submit', async ($, e, next) => {
    const r = await next(e)
    if (e.origin?.kind === 'task-notification' && ENDED.test(e.text)) {
      const ended = /<task-id>\s*([^<\s]+)\s*<\/task-id>/.exec(e.text)?.[1]
      if (ended) await update($, tasks, list => list.filter(t => t.id !== ended))
    }
    $.clock.after(0, () => void apply($, 'working', true).catch(() => {}))
    return r
  }).catch(($, e, next) => next(e))

  // The main loop's turn ended: background work in flight → ⏳, else Haiku reads the answer.
  // Only the icon changes; the session stays in its section.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    // An interrupted turn leaves no answer to read: only the 🔄 goes.
    if (e.isAborted) {
      $.clock.after(0, () => void apply($, null, false).catch(() => {}))
      return r
    }
    answer = e.answer
    $.clock.after(0, () => {
      void (async () => {
        try {
          const inFlight = (await read($, tasks)).length
          const status: Status = inFlight > 0 ? 'running' : await classify($, answer)
          await apply($, status, false)
        } catch {}
      })()
    })
    return r
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    startInit($)
    const list = await read($, tasks)
    const isDone = (await read($, shown)) === 'done'
    if (e.props.hasSurvey || (list.length === 0 && !isDone)) return next(e)

    const { Box, Button, Link, Text } = $.ui.resolve(e)
    const at = await read($, now)
    const open = await read($, isExpanded)
    const visible = open ? list : list.slice(0, FOLDED_ROWS)
    const width = Math.max(20, (e.props.bodyColumns ?? 80) - 32)
    return (
      <Box flexDirection="column">
        {list.length > 0 && <Text bold>⏳ Фоновые задачи · {list.length}</Text>}
        {visible.map(t => (
          <Box key={t.id}>
            <Text>
              <Text dimColor>{t.kind.padEnd(8)}</Text>
              {t.label.length > width ? t.label.slice(0, width - 1) + '…' : t.label}
              <Text dimColor>  {elapsed(Math.max(0, at - t.startedAt))}  </Text>
            </Text>
            {t.link && <Link href={t.link.href} label={t.link.label} />}
          </Box>
        ))}
        {list.length > FOLDED_ROWS && (
          <Button
            key="expand"
            label={open ? 'Свернуть' : `Показать все (${list.length})`}
            onPress={() => void update($, isExpanded, v => !v)}
          />
        )}
        {isDone && (
          <Box>
            <Text>✅ Задача готова </Text>
            <Button key="ack" label="Принято" onPress={() => void apply($, null, false).catch(() => {})} />
          </Box>
        )}
      </Box>
    )
  })
}

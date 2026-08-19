// End-to-end test against an in-process fake Mattermost (REST + WebSocket via Bun.serve).
// Bun-only: skipped under `node --test`. Spawns `server.ts serve`, drives it over MCP stdio and
// checks: DM / @mention / bot-thread delivery, whitelist drop, plain-post ignore, permission relay
// to the sender's DM, `yes <code>` intercept, `reply` (threaded) and `react`.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

declare const Bun: any
const HAS_BUN = typeof Bun !== 'undefined'
const BOT = 'botid00000000000000000000000'
const HUMAN = 'humanid000000000000000000000'
const OTHER = 'otherid000000000000000000000'

test('connector e2e against fake Mattermost', { skip: !HAS_BUN, timeout: 30000 }, async () => {
  const created: any[] = []
  const reactions: string[] = []
  const typing: string[] = []
  const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } })

  const fake = Bun.serve({
    port: 0,
    fetch(req: Request, srv: any) {
      const url = new URL(req.url)
      if (url.pathname === '/api/v4/websocket') return srv.upgrade(req) ? undefined : new Response('no', { status: 400 })
      const p = url.pathname.replace('/api/v4', '')
      if (req.headers.get('authorization') !== 'Bearer good') return json({ message: 'unauthorized' }, 401)
      if (p === '/users/me') return json({ id: BOT, username: 'claude-bot', is_bot: true })
      if (p === '/users/me/teams') return json([{ id: 't1', name: 'your-team', display_name: 'Team' }])
      if (p === '/users/usernames') return json([{ id: HUMAN, username: 'j.doe' }])
      if (p === `/users/${HUMAN}`) return json({ id: HUMAN, username: 'j.doe' })
      if (p === `/users/${OTHER}`) return json({ id: OTHER, username: 'stranger' })
      if (p === '/teams/t1') return json({ id: 't1', name: 'your-team' })
      if (p === '/channels/dm1') return json({ id: 'dm1', type: 'D', team_id: '' })
      if (p === '/channels/c1') return json({ id: 'c1', type: 'O', team_id: 't1' })
      if (p === '/posts/root-bot') return json({ id: 'root-bot', user_id: BOT, channel_id: 'c1', root_id: '' })
      if (p === '/posts' && req.method === 'POST') return req.json().then((b: any) => { created.push(b); return json({ id: 'np' + created.length, ...b }) })
      if (p === '/reactions') return req.json().then((b: any) => { reactions.push(`${b.emoji_name}:${b.post_id}`); return json(b) })
      if (p === '/channels/direct') return json({ id: 'dm1', type: 'D' })
      return json({ message: 'not found ' + p }, 404)
    },
    websocket: {
      message(ws: any, raw: string) {
        const m = JSON.parse(String(raw))
        if (m.action === 'user_typing') { typing.push(`${m.data.channel_id}:${m.data.parent_id}`); return }
        if (m.action !== 'authentication_challenge') return
        if (m.data.token !== 'good') { ws.send(JSON.stringify({ status: 'FAIL', seq_reply: m.seq, error: { id: 'bad' } })); return }
        ws.send(JSON.stringify({ status: 'OK', seq_reply: m.seq }))
        ws.send(JSON.stringify({ event: 'hello', data: {}, seq: 0 }))
        const posted = (post: any, data: any = {}) =>
          ws.send(JSON.stringify({ event: 'posted', seq: 1, data: { channel_type: 'O', channel_name: 'dev', channel_display_name: 'Dev', team_id: 't1', sender_name: '@j.doe', post: JSON.stringify({ type: '', create_at: 1700000000000, file_ids: [], ...post }), ...data } }))
        setTimeout(() => posted({ id: 'p-dm', channel_id: 'dm1', root_id: '', user_id: HUMAN, message: 'hello from dm' }, { channel_type: 'D', channel_name: 'x__y', team_id: '' }), 100)
        setTimeout(() => posted({ id: 'p-stranger', channel_id: 'dm2', root_id: '', user_id: OTHER, message: 'let me in' }, { channel_type: 'D', sender_name: '@stranger' }), 200)
        setTimeout(() => posted({ id: 'p-mention', channel_id: 'c1', root_id: '', user_id: HUMAN, message: '@claude-bot ping' }, { mentions: JSON.stringify([BOT]) }), 300)
        setTimeout(() => posted({ id: 'p-thread', channel_id: 'c1', root_id: 'root-bot', user_id: HUMAN, message: 'follow-up' }), 400)
        setTimeout(() => posted({ id: 'p-plain', channel_id: 'c1', root_id: '', user_id: HUMAN, message: 'nothing' }), 500)
        setTimeout(() => posted({ id: 'p-yes', channel_id: 'dm1', root_id: '', user_id: HUMAN, message: 'yes abcde' }, { channel_type: 'D' }), 900)
      },
    },
  })

  const here = dirname(fileURLToPath(import.meta.url))
  const child = spawn('bun', [join(here, '..', 'server.ts'), 'serve'], {
    env: { ...process.env, TIME_BOT_TOKEN: 'good', TIME_BASE_URL: `http://127.0.0.1:${fake.port}`, TIME_CONNECTOR_ALLOWED_USERS: 'j.doe', TIME_TEAM_CONFIG: '' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const notifications: any[] = []
  const results = new Map<number, any>()
  const stderr: string[] = []
  let buf = ''
  child.stdout.on('data', d => {
    buf += d
    const lines = buf.split('\n')
    buf = lines.pop()!
    for (const l of lines) {
      const m = JSON.parse(l)
      if (m.method) notifications.push(m)
      else results.set(m.id, m.result)
    }
  })
  child.stderr.on('data', d => stderr.push(String(d)))
  const send = (o: unknown) => child.stdin.write(JSON.stringify(o) + '\n')
  const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

  try {
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'e2e', version: '0' } } })
    send({ jsonrpc: '2.0', method: 'notifications/initialized' })
    await sleep(1400)
    send({ jsonrpc: '2.0', method: 'notifications/claude/channel/permission_request', params: { request_id: 'abcde', tool_name: 'Bash', description: 'ls', input_preview: '{"command":"ls"}' } })
    await sleep(300)
    send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'reply', arguments: { channel_id: 'dm1', text: 'hi back' } } })
    send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'reply', arguments: { channel_id: 'c1', text: 'pong', root_id: 'p-mention' } } })
    send({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'reply', arguments: { channel_id: 'elsewhere', text: 'nope' } } })
    send({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'react', arguments: { post_id: 'p-dm', emoji: ':white_check_mark:' } } })
    await sleep(800)

    const init = results.get(1)
    assert.ok(init.capabilities.experimental['claude/channel'])
    assert.ok(init.capabilities.experimental['claude/channel/permission'])
    assert.match(init.instructions, /@claude-bot/)

    const inbound = notifications.filter(n => n.method === 'notifications/claude/channel').map(n => n.params)
    assert.deepEqual(inbound.map(i => [i.meta.kind, i.meta.post_id, i.meta.root_id]), [
      ['dm', 'p-dm', ''],
      ['mention', 'p-mention', 'p-mention'],
      ['thread', 'p-thread', 'root-bot'],
    ])
    assert.equal(inbound[0].content, 'hello from dm')
    assert.equal(inbound[0].meta.user, 'j.doe')
    assert.equal(inbound[0].meta.channel, 'DM')
    assert.equal(inbound[1].meta.permalink, `http://127.0.0.1:${fake.port}/your-team/pl/p-mention`)
    assert.ok(stderr.join('').includes('drop: @stranger not in whitelist'))

    // permission relay → DM post, and "yes abcde" intercepted (not forwarded as inbound)
    const perm = notifications.find(n => n.method === 'notifications/claude/channel/permission')
    assert.deepEqual(perm.params, { request_id: 'abcde', behavior: 'allow' })
    assert.ok(created.some(p => p.channel_id === 'dm1' && /yes abcde/.test(p.message) && !p.root_id))
    assert.ok(reactions.includes('white_check_mark:p-yes'))

    // replies
    assert.match(results.get(3).content[0].text, /^sent \(post_id: np\d+\)/)
    assert.ok(created.some(p => p.channel_id === 'dm1' && p.message === 'hi back' && !p.root_id))
    assert.ok(created.some(p => p.channel_id === 'c1' && p.message === 'pong' && p.root_id === 'p-mention'))
    assert.equal(results.get(5).isError, true)
    assert.match(results.get(6).content[0].text, /reacted :white_check_mark:/)

    // side effects
    assert.ok(typing.includes('dm1:') && typing.includes('c1:p-mention') && typing.includes('c1:root-bot'))
    assert.ok(reactions.includes('eyes:p-dm'))
  } finally {
    child.stdin.end()
    await new Promise(r => child.on('exit', r))
    fake.stop(true)
  }
})

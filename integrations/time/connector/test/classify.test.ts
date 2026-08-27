import { test } from 'node:test'
import assert from 'node:assert/strict'
import { classify, mentionsBot, parsePostedEvent, type ClassifyCtx } from '../src/classify.ts'

const BOT = 'botuserid000000000000000000'
const HUMAN = 'humanuserid00000000000000000'

function posted(post: Record<string, unknown>, data: Record<string, unknown> = {}) {
  return {
    event: 'posted',
    data: {
      channel_type: 'O',
      channel_name: 'dev',
      channel_display_name: 'Dev',
      team_id: 'team1',
      sender_name: '@j.doe',
      post: JSON.stringify({ id: 'p1', channel_id: 'c1', root_id: '', user_id: HUMAN, message: 'hi', type: '', create_at: 1700000000000, ...post }),
      ...data,
    },
    broadcast: { channel_id: 'c1' },
    seq: 5,
  }
}

function ctx(over: Partial<ClassifyCtx> = {}): ClassifyCtx {
  return {
    botUserId: BOT,
    botUsername: 'claude-bot',
    isBotThreadRoot: () => false,
    isEngagedThread: () => false,
    ...over,
  }
}

test('parsePostedEvent: post and mentions are JSON strings', () => {
  const p = parsePostedEvent(posted({}, { mentions: JSON.stringify([BOT]) }))
  assert.ok(p)
  assert.equal(p.post.id, 'p1')
  assert.equal(p.post.message, 'hi')
  assert.deepEqual(p.data.mentions, [BOT])
  assert.equal(p.data.channel_type, 'O')
})

test('parsePostedEvent: accepts already-parsed objects, rejects other events and system posts', () => {
  const ev = posted({})
  ;(ev.data as any).post = JSON.parse(ev.data.post as string)
  assert.ok(parsePostedEvent(ev))
  assert.equal(parsePostedEvent({ event: 'typing', data: {} }), null)
  assert.equal(parsePostedEvent(posted({ type: 'system_join_channel' })), null)
  assert.equal(parsePostedEvent(null), null)
  assert.equal(parsePostedEvent({ event: 'posted', data: { post: '{not json' } }), null)
})

test('own posts are ignored even in DMs', async () => {
  const p = parsePostedEvent(posted({ user_id: BOT }, { channel_type: 'D' }))!
  assert.equal(await classify(p, ctx()), null)
})

test('DM → dm, plain reply unless sender threaded', async () => {
  const a = await classify(parsePostedEvent(posted({}, { channel_type: 'D' }))!, ctx())
  assert.equal(a?.kind, 'dm')
  assert.equal(a?.reply_root_id, '')
  const b = await classify(parsePostedEvent(posted({ root_id: 'r9' }, { channel_type: 'D' }))!, ctx())
  assert.equal(b?.kind, 'dm')
  assert.equal(b?.reply_root_id, 'r9')
})

test('reply in a thread rooted by the bot → thread', async () => {
  const p = parsePostedEvent(posted({ root_id: 'root1' }))!
  const r = await classify(p, ctx({ isBotThreadRoot: async id => id === 'root1' }))
  assert.equal(r?.kind, 'thread')
  assert.equal(r?.reply_root_id, 'root1')
})

test('reply in an engaged thread → thread (no API lookup needed)', async () => {
  let looked = false
  const p = parsePostedEvent(posted({ root_id: 'root2' }))!
  const r = await classify(p, ctx({ isEngagedThread: id => id === 'root2', isBotThreadRoot: () => { looked = true; return false } }))
  assert.equal(r?.kind, 'thread')
  assert.equal(looked, false)
})

test('@mention via mentions array → mention, threaded under the triggering post', async () => {
  const p = parsePostedEvent(posted({}, { mentions: JSON.stringify([BOT, 'other']) }))!
  const r = await classify(p, ctx())
  assert.equal(r?.kind, 'mention')
  assert.equal(r?.reply_root_id, 'p1')
})

test('@mention inside someone else\'s thread keeps that thread', async () => {
  const p = parsePostedEvent(posted({ root_id: 'hr', message: '@claude-bot look' }))!
  const r = await classify(p, ctx())
  assert.equal(r?.kind, 'mention')
  assert.equal(r?.reply_root_id, 'hr')
})

test('text fallback mention when mentions array is missing', async () => {
  const p = parsePostedEvent(posted({ message: 'hey @Claude-Bot, status?' }))!
  assert.equal((await classify(p, ctx()))?.kind, 'mention')
})

test('plain channel post without mention → null', async () => {
  assert.equal(await classify(parsePostedEvent(posted({ message: 'nothing for the bot' }))!, ctx()), null)
})

test('precedence: mention inside a bot thread is delivered once as thread', async () => {
  const p = parsePostedEvent(posted({ root_id: 'root1', message: '@claude-bot more' }, { mentions: JSON.stringify([BOT]) }))!
  const r = await classify(p, ctx({ isBotThreadRoot: () => true }))
  assert.equal(r?.kind, 'thread')
})

test('mentionsBot boundaries', () => {
  assert.equal(mentionsBot('@claude-bot hi', 'claude-bot'), true)
  assert.equal(mentionsBot('(@claude-bot)', 'claude-bot'), true)
  assert.equal(mentionsBot('mail@claude-bot.example', 'claude-bot'), false)
  assert.equal(mentionsBot('@claude-bot2 hi', 'claude-bot'), false)
  assert.equal(mentionsBot('hi', ''), false)
})

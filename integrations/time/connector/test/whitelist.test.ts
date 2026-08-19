import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseAllowedUsers, parseEnvList, parseTeamConfigUsers } from '../src/whitelist.ts'

test('team-config wins over env', () => {
  const r = parseAllowedUsers({
    teamConfigJson: JSON.stringify({ time: { connector: { allowed_users: ['j.doe'] } } }),
    envValue: 'a.smith',
  })
  assert.deepEqual(r, { users: ['j.doe'], source: 'team-config' })
})

test('env fallback when team-config has no connector section', () => {
  const r = parseAllowedUsers({
    teamConfigJson: JSON.stringify({ time: { channels: {} } }),
    envValue: 'a.smith, @J.Doe ,a.smith',
  })
  assert.deepEqual(r, { users: ['a.smith', 'j.doe'], source: 'env' })
})

test('nothing configured → empty with source none', () => {
  assert.deepEqual(parseAllowedUsers({}), { users: [], source: 'none' })
  assert.deepEqual(parseAllowedUsers({ teamConfigJson: '{bad json', envValue: '' }), { users: [], source: 'none' })
})

test('empty array in team-config is authoritative (does not fall back to env)', () => {
  const r = parseAllowedUsers({
    teamConfigJson: JSON.stringify({ time: { connector: { allowed_users: [] } } }),
    envValue: 'a.smith',
  })
  assert.deepEqual(r, { users: [], source: 'team-config' })
})

test('normalisation: strip @, lowercase, dedupe, drop non-strings', () => {
  assert.deepEqual(parseTeamConfigUsers(JSON.stringify({ time: { connector: { allowed_users: ['@A.B', 'a.b', 42, ' c '] } } })), ['a.b', 'c'])
  assert.deepEqual(parseEnvList('x;y'), ['x;y'])
  assert.deepEqual(parseEnvList(' x  y,z '), ['x', 'y', 'z'])
})

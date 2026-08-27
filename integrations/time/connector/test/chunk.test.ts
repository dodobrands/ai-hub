import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chunk } from '../src/chunk.ts'

test('short text is returned as a single chunk', () => {
  assert.deepEqual(chunk('hello', 10), ['hello'])
})

test('newline mode prefers paragraph boundary', () => {
  const text = 'aaaa aaaa\n\nbbbb bbbb\n\ncccc'
  const parts = chunk(text, 12, 'newline')
  assert.deepEqual(parts, ['aaaa aaaa', 'bbbb bbbb', 'cccc'])
  for (const p of parts) assert.ok(p.length <= 12)
})

test('length mode hard-cuts', () => {
  assert.deepEqual(chunk('abcdefghij', 4, 'length'), ['abcd', 'efgh', 'ij'])
})

test('falls back to hard cut when no boundary', () => {
  const parts = chunk('x'.repeat(25), 10)
  assert.deepEqual(parts, ['x'.repeat(10), 'x'.repeat(10), 'x'.repeat(5)])
})

test('limit <= 0 disables chunking', () => {
  assert.deepEqual(chunk('abc', 0), ['abc'])
})

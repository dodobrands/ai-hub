// Split long replies so every part fits the Mattermost post limit.
// Ported from the official Telegram/Discord channel plugins (anthropics/claude-plugins-official).
// 'newline' mode prefers paragraph → line → space boundaries past limit/2, else a hard cut.

export type ChunkMode = 'length' | 'newline'

export function chunk(text: string, limit: number, mode: ChunkMode = 'newline'): string[] {
  if (limit <= 0) return [text]
  if (text.length <= limit) return [text]
  const out: string[] = []
  let rest = text
  while (rest.length > limit) {
    let cut = limit
    if (mode === 'newline') {
      const para = rest.lastIndexOf('\n\n', limit)
      const line = rest.lastIndexOf('\n', limit)
      const space = rest.lastIndexOf(' ', limit)
      cut = para > limit / 2 ? para : line > limit / 2 ? line : space > 0 ? space : limit
    }
    out.push(rest.slice(0, cut))
    rest = rest.slice(cut).replace(/^\n+/, '')
  }
  if (rest) out.push(rest)
  return out
}

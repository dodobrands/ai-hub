// Whitelist of Time usernames allowed to talk to the connector.
// Pure module — no I/O, no deps — so it is unit-testable under `node --test` and `bun test`.
//
// Priority: team-config.json → .time.connector.allowed_users (array of strings)
//           else env TIME_CONNECTOR_ALLOWED_USERS (comma/space separated)
// Normalisation: trim, strip leading '@', lowercase, drop empties, dedupe (order preserved).

export type WhitelistSource = 'team-config' | 'env' | 'none'

export type WhitelistResult = {
  users: string[]
  source: WhitelistSource
}

export function normalizeUsername(raw: string): string {
  return raw.trim().replace(/^@+/, '').toLowerCase()
}

function dedupe(list: string[]): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  for (const raw of list) {
    const u = normalizeUsername(String(raw))
    if (!u || seen.has(u)) continue
    seen.add(u)
    out.push(u)
  }
  return out
}

export function parseEnvList(value: string | null | undefined): string[] {
  if (!value) return []
  return dedupe(value.split(/[,\s]+/))
}

/**
 * Extracts `.time.connector.allowed_users` from a team-config.json text.
 * Returns null if absent, invalid or EMPTY (the example config ships `[]`) so the env fallback still applies.
 */
export function parseTeamConfigUsers(json: string | null | undefined): string[] | null {
  if (!json) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(json)
  } catch {
    return null
  }
  const users = (parsed as any)?.time?.connector?.allowed_users
  if (!Array.isArray(users)) return null
  const list = dedupe(users.filter((u: unknown) => typeof u === 'string'))
  return list.length ? list : null
}

export function parseAllowedUsers(opts: {
  teamConfigJson?: string | null
  envValue?: string | null
}): WhitelistResult {
  const fromConfig = parseTeamConfigUsers(opts.teamConfigJson)
  if (fromConfig !== null) return { users: fromConfig, source: 'team-config' }
  const fromEnv = parseEnvList(opts.envValue)
  if (fromEnv.length) return { users: fromEnv, source: 'env' }
  return { users: [], source: 'none' }
}

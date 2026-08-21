// Runtime configuration from environment. The bash launcher (scripts/time-connector.sh)
// loads .env via hub-meta/scripts/load-env.sh and exports TIME_TEAM_CONFIG, so this module
// only reads process.env and (optionally) the team-config.json file.
import { readFileSync } from 'node:fs'
import { parseAllowedUsers, type WhitelistResult } from './whitelist.ts'

export type Config = {
  baseUrl: string
  token: string
  whitelist: WhitelistResult
  teamConfigPath: string
  ackReaction: string // '' disables
  chunkLimit: number
  ignoreBots: boolean
  serverName: string
}

export const DEFAULT_BASE_URL = 'https://your-company.time-messenger.ru'

function intEnv(value: string | undefined, fallback: number): number {
  const n = Number(value)
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const token = (env.TIME_BOT_TOKEN ?? '').trim()
  if (!token) {
    throw new Error('TIME_BOT_TOKEN is not set — add the bot token to .env (see integrations/time/README.md, section "Connector")')
  }
  const baseUrl = (env.TIME_BASE_URL || DEFAULT_BASE_URL).replace(/\/+$/, '')
  const teamConfigPath = env.TIME_TEAM_CONFIG ?? ''
  let teamConfigJson: string | null = null
  if (teamConfigPath) {
    try {
      teamConfigJson = readFileSync(teamConfigPath, 'utf8')
    } catch {
      teamConfigJson = null
    }
  }
  const whitelist = parseAllowedUsers({ teamConfigJson, envValue: env.TIME_CONNECTOR_ALLOWED_USERS })
  return {
    baseUrl,
    token,
    whitelist,
    teamConfigPath,
    ackReaction: env.TIME_CONNECTOR_ACK_REACTION === undefined ? 'eyes' : env.TIME_CONNECTOR_ACK_REACTION.trim(),
    chunkLimit: intEnv(env.TIME_CONNECTOR_CHUNK_LIMIT, 16000),
    ignoreBots: env.TIME_CONNECTOR_IGNORE_BOTS !== 'false',
    serverName: 'time-connector',
  }
}

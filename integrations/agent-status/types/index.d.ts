export type BackgroundTask = {
  id: string
  kind: string
  label: string
  startedAt: number
  link?: { href: string; label: string }
}

declare module 'claude-code' {
  interface PluginState {
    'agent-status': {
      shown: 'working' | 'running' | 'ask' | 'done' | 'failed' | null
      tasks: BackgroundTask[]
      isExpanded: boolean
      now: number
    }
  }
}

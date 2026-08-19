// Minimal Mattermost API v4 client: REST over fetch + WebSocket event stream.
// Only globals (fetch, WebSocket) — works on Bun and Node >= 22 without deps.

export type MmUser = { id: string; username: string; is_bot?: boolean; first_name?: string; last_name?: string }
export type MmTeam = { id: string; name: string; display_name: string }
export type MmPost = { id: string; channel_id: string; root_id: string; user_id: string; message: string; create_at: number }
export type MmChannel = { id: string; type: string; name: string; display_name: string; team_id: string }

export class MattermostApiError extends Error {
  status: number
  method: string
  path: string
  constructor(status: number, method: string, path: string, body: string) {
    super(`${method} ${path} → HTTP ${status}: ${body.slice(0, 300)}`)
    this.status = status
    this.method = method
    this.path = path
  }
}

export class MattermostRest {
  private userCache = new Map<string, { user: MmUser; at: number }>()
  private teamCache = new Map<string, MmTeam>()
  private static USER_TTL = 60 * 60 * 1000
  baseUrl: string
  private token: string

  constructor(baseUrl: string, token: string) {
    this.baseUrl = baseUrl
    this.token = token
  }

  async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await fetch(`${this.baseUrl}/api/v4${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.token}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    if (!res.ok) throw new MattermostApiError(res.status, method, path, text)
    return (text ? JSON.parse(text) : null) as T
  }

  me(): Promise<MmUser> {
    return this.request<MmUser>('GET', '/users/me')
  }

  myTeams(): Promise<MmTeam[]> {
    return this.request<MmTeam[]>('GET', '/users/me/teams')
  }

  async getUsersByUsernames(usernames: string[]): Promise<MmUser[]> {
    if (!usernames.length) return []
    const users = await this.request<MmUser[]>('POST', '/users/usernames', usernames)
    for (const u of users) this.userCache.set(u.id, { user: u, at: Date.now() })
    return users
  }

  async getUser(id: string): Promise<MmUser | null> {
    const hit = this.userCache.get(id)
    if (hit && Date.now() - hit.at < MattermostRest.USER_TTL) return hit.user
    try {
      const user = await this.request<MmUser>('GET', `/users/${id}`)
      this.userCache.set(id, { user, at: Date.now() })
      return user
    } catch (e) {
      if (e instanceof MattermostApiError && e.status === 404) return null
      throw e
    }
  }

  async getTeam(id: string): Promise<MmTeam | null> {
    if (!id) return null
    const hit = this.teamCache.get(id)
    if (hit) return hit
    try {
      const team = await this.request<MmTeam>('GET', `/teams/${id}`)
      this.teamCache.set(id, team)
      return team
    } catch (e) {
      if (e instanceof MattermostApiError && (e.status === 404 || e.status === 403)) return null
      throw e
    }
  }

  getPost(id: string): Promise<MmPost> {
    return this.request<MmPost>('GET', `/posts/${id}`)
  }

  getChannel(id: string): Promise<MmChannel> {
    return this.request<MmChannel>('GET', `/channels/${id}`)
  }

  createPost(input: { channel_id: string; message: string; root_id?: string }): Promise<MmPost> {
    const body: Record<string, string> = { channel_id: input.channel_id, message: input.message }
    if (input.root_id) body.root_id = input.root_id
    return this.request<MmPost>('POST', '/posts', body)
  }

  addReaction(input: { user_id: string; post_id: string; emoji_name: string }): Promise<unknown> {
    return this.request('POST', '/reactions', input)
  }

  createDirectChannel(userA: string, userB: string): Promise<MmChannel> {
    return this.request<MmChannel>('POST', '/channels/direct', [userA, userB])
  }
}

export type WsEvent = { event?: string; data?: Record<string, unknown>; seq?: number; seq_reply?: number; status?: string; error?: unknown }

export type WsOptions = {
  onEvent: (ev: WsEvent) => void
  onAuth?: () => void
  log: (msg: string) => void
  /** No frames for this long → force reconnect (half-open TCP guard). */
  livenessMs?: number
}

export class MattermostWs {
  private ws: WebSocket | null = null
  private seq = 1
  private attempt = 0
  private closedByUs = false
  private liveness: ReturnType<typeof setTimeout> | null = null
  private authSeq = 0
  private baseUrl: string
  private token: string
  private opts: WsOptions

  constructor(baseUrl: string, token: string, opts: WsOptions) {
    this.baseUrl = baseUrl
    this.token = token
    this.opts = opts
  }

  get connected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN
  }

  connect(): void {
    if (this.closedByUs) return
    const url = this.baseUrl.replace(/^http/, 'ws') + '/api/v4/websocket'
    let ws: WebSocket
    try {
      ws = new WebSocket(url)
    } catch (e) {
      this.opts.log(`ws: cannot create socket: ${e}`)
      this.scheduleReconnect()
      return
    }
    this.ws = ws
    ws.onopen = () => {
      // Native WebSocket cannot set Authorization headers → authenticate in-band.
      this.authSeq = this.seq++
      ws.send(JSON.stringify({ seq: this.authSeq, action: 'authentication_challenge', data: { token: this.token } }))
      this.bumpLiveness()
    }
    ws.onmessage = m => {
      this.bumpLiveness()
      let msg: WsEvent
      try {
        msg = JSON.parse(String(m.data))
      } catch {
        return
      }
      if (msg.event === 'hello') {
        this.attempt = 0
        this.opts.log('ws: authenticated')
        this.opts.onAuth?.()
        return
      }
      if (msg.seq_reply === this.authSeq && msg.status === 'FAIL') {
        this.opts.log(`ws: authentication failed — check TIME_BOT_TOKEN (${JSON.stringify(msg.error)})`)
        ws.close()
        return
      }
      if (msg.event) {
        try {
          this.opts.onEvent(msg)
        } catch (e) {
          this.opts.log(`ws: handler error: ${e}`)
        }
      }
    }
    ws.onerror = (e: Event & { message?: string }) => {
      this.opts.log(`ws: error ${e.message ?? ''}`.trim())
    }
    ws.onclose = () => {
      this.clearLiveness()
      if (this.ws === ws) this.ws = null
      if (this.closedByUs) return
      this.scheduleReconnect()
    }
  }

  private scheduleReconnect(): void {
    const base = Math.min(1000 * 2 ** this.attempt, 30000)
    const delay = base + Math.floor(Math.random() * 500)
    this.attempt = Math.min(this.attempt + 1, 10)
    this.opts.log(`ws: disconnected, reconnect in ${delay}ms`)
    setTimeout(() => this.connect(), delay).unref?.()
  }

  private bumpLiveness(): void {
    this.clearLiveness()
    const ms = this.opts.livenessMs ?? 90000
    this.liveness = setTimeout(() => {
      this.opts.log('ws: no frames received, forcing reconnect')
      this.ws?.close()
    }, ms)
    this.liveness.unref?.()
  }

  private clearLiveness(): void {
    if (this.liveness) clearTimeout(this.liveness)
    this.liveness = null
  }

  typing(channel_id: string, parent_id = ''): void {
    if (!this.connected) return
    try {
      this.ws!.send(JSON.stringify({ seq: this.seq++, action: 'user_typing', data: { channel_id, parent_id } }))
    } catch {}
  }

  close(): void {
    this.closedByUs = true
    this.clearLiveness()
    try {
      this.ws?.close()
    } catch {}
  }
}

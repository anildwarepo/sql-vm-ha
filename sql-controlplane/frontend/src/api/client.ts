// Typed client for the FastAPI backend. All requests are same-origin (/api); Vite proxies them in development.
import type { ActionResult, ChatEvent, DashboardSnapshot, Health } from './types'

const CLIENT_HEADER = { 'X-SQLHA-Client': 'ui' }

export class ApiError extends Error {
  status: number
  code: string
  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: { ...(method === 'GET' ? {} : CLIENT_HEADER), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (res.status === 204) return undefined as T
  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    const err = (data as { error?: { code?: string; message?: string } }).error
    throw new ApiError(res.status, err?.code ?? 'http_error', err?.message ?? `HTTP ${res.status}`)
  }
  return data as T
}

export const api = {
  health: () => request<Health>('GET', '/api/health'),
  snapshot: () => request<DashboardSnapshot>('GET', '/api/dashboard/snapshot'),
  refresh: () => request<{ generated_at: string; duration_s: number }>('POST', '/api/dashboard/refresh'),
  patchPlan: (machine: string) => request<ActionResult>('GET', `/api/sql/patching/plan/${encodeURIComponent(machine)}`),
  assess: (machine: string, confirm: boolean) =>
    request<ActionResult>('POST', `/api/sql/actions/machines/${encodeURIComponent(machine)}/assessment`, { confirm }),
  installPatches: (machine: string, confirm: boolean, options: { failover_first?: boolean } = {}) =>
    request<ActionResult>('POST', `/api/sql/actions/machines/${encodeURIComponent(machine)}/install-patches`, { confirm, ...options }),
  failover: (target_instance: string, confirm: boolean, ag_name?: string) =>
    request<ActionResult>('POST', '/api/sql/actions/failover', { target_instance, ag_name, confirm }),
  endChat: (sessionId: string) => request<void>('DELETE', `/api/chat/sessions/${encodeURIComponent(sessionId)}`),
}

/** POST a chat message and yield Server-Sent Events as they arrive. */
export async function* streamChat(
  message: string, sessionId: string | null, context: string, signal?: AbortSignal,
): AsyncGenerator<ChatEvent> {
  const res = await fetch('/api/chat/messages', {
    method: 'POST',
    headers: { ...CLIENT_HEADER, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message, session_id: sessionId ?? undefined, context }),
    signal,
  })
  if (!res.ok || !res.body) {
    const data = await res.json().catch(() => ({}))
    throw new ApiError(res.status, 'chat_error', (data as { error?: { message?: string } }).error?.message ?? `HTTP ${res.status}`)
  }
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    let idx: number
    while ((idx = buffer.indexOf('\n\n')) >= 0) {
      const line = buffer.slice(0, idx).replace(/^data: /, '')
      buffer = buffer.slice(idx + 2)
      if (line) yield JSON.parse(line) as ChatEvent
    }
  }
}

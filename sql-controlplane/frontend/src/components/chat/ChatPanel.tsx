import { useEffect, useRef, useState } from 'react'
import { api, streamChat } from '../../api/client'
import { Markdown } from '../common/Markdown'

const TOOL_LABEL: Record<string, string> = {
  sqlha_get_overview: 'overview', sqlha_get_inventory: 'inventory', sqlha_get_availability_groups: 'Always On (live)',
  sqlha_get_patch_compliance: 'patch compliance', sqlha_get_patch_history: 'patch history',
  sqlha_get_maintenance_windows: 'maintenance windows', sqlha_get_security_posture: 'security',
  sqlha_get_databases: 'databases', sqlha_get_orchestration_jobs: 'runbook jobs', sqlha_get_job_output: 'job output',
  sqlha_plan_patch_install: 'patch preflight', sqlha_get_performance_snapshot: 'performance snapshot (~30 s)',
  sqlha_query_resource_graph: 'Resource Graph', sqlha_get_operation_status: 'operation status',
}

const SUGGESTIONS = [
  'Give me a status report',
  'Who is the primary and is everything synchronized?',
  'What patches are outstanding?',
  'When is the next maintenance window for each node?',
  'How is SQL performance right now?',
  'Why was the last patch wave cancelled?',
  'What are the top security risks?',
]

interface Message {
  role: 'user' | 'bot'
  text: string
  tools?: string[]
  seconds?: number
  error?: string
  pending?: boolean
}

interface Conversation { sessionId: string | null; messages: Message[] }

const STORAGE_KEY = 'sqlha-chat'

function load(): Conversation {
  try {
    const c = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? 'null') as Conversation | null
    if (!c) return { sessionId: null, messages: [] }
    // An answer that was streaming when the page reloaded can't resume.
    c.messages = c.messages.map(m => (m.pending ? { ...m, pending: false, error: m.error ?? 'Interrupted. Ask again.' } : m))
    return c
  } catch {
    return { sessionId: null, messages: [] }
  }
}

interface ChatPanelProps {
  open: boolean
  onClose: () => void
  context: string
  configured: boolean
}

export function ChatPanel({ open, onClose, context, configured }: ChatPanelProps) {
  const [conv, setConv] = useState<Conversation>(load)
  const [input, setInput] = useState('')
  const [busy, setBusy] = useState(false)
  const logRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const abortRef = useRef<AbortController | null>(null)

  useEffect(() => { sessionStorage.setItem(STORAGE_KEY, JSON.stringify(conv)) }, [conv])
  useEffect(() => { logRef.current?.scrollTo({ top: logRef.current.scrollHeight }) }, [conv])
  useEffect(() => { if (open) inputRef.current?.focus() }, [open])
  useEffect(() => () => abortRef.current?.abort(), [])

  const updateLast = (fn: (m: Message) => Message) =>
    setConv(c => ({ ...c, messages: [...c.messages.slice(0, -1), fn(c.messages[c.messages.length - 1])] }))

  async function ask(question: string) {
    const text = question.trim()
    if (!text || busy) return
    setBusy(true)
    setInput('')
    setConv(c => ({ ...c, messages: [...c.messages, { role: 'user', text }, { role: 'bot', text: '', tools: [], pending: true }] }))
    const ctrl = new AbortController()
    abortRef.current = ctrl
    try {
      for await (const ev of streamChat(text, conv.sessionId, context, ctrl.signal)) {
        if (ev.type === 'session') setConv(c => ({ ...c, sessionId: ev.id }))
        else if (ev.type === 'tool') updateLast(m => ({ ...m, tools: m.tools?.includes(ev.name) ? m.tools : [...(m.tools ?? []), ev.name] }))
        else if (ev.type === 'text') updateLast(m => ({ ...m, text: m.text + ev.delta }))
        else if (ev.type === 'done') updateLast(m => ({ ...m, seconds: ev.seconds }))
        else if (ev.type === 'error') updateLast(m => ({ ...m, error: ev.message }))
      }
      updateLast(m => ({ ...m, pending: false, error: m.error ?? (m.text ? undefined : 'No answer was returned.') }))
    } catch (e) {
      if (!ctrl.signal.aborted) updateLast(m => ({ ...m, pending: false, error: `Chat failed: ${(e as Error).message}` }))
    } finally {
      setBusy(false)
      inputRef.current?.focus()
    }
  }

  function newChat() {
    if (busy) return
    if (conv.sessionId) api.endChat(conv.sessionId).catch(() => undefined)
    setConv({ sessionId: null, messages: [] })
  }

  return (
    <section className={`chat ${open ? '' : 'hidden'}`} aria-label="Ask SQL HA">
      <header className="chat-head">
        <b>💬 Ask SQL HA</b>
        <span className="pill info">read-only</span>
        <div className="spacer" />
        <button onClick={newChat} disabled={busy}>New chat</button>
        <button className="icon" onClick={onClose} aria-label="Close">✕</button>
      </header>
      <div className="chat-log" ref={logRef}>
        {!configured && (
          <div className="msg bot err">Chat isn't configured. Set FOUNDRY_PROJECT_ENDPOINT and AZURE_AI_MODEL_DEPLOYMENT_NAME in sql-controlplane/.env and restart the backend.</div>
        )}
        {conv.messages.length === 0 ? (
          <div className="msg bot">Ask about Always On health, outstanding patches, maintenance windows, security findings, metadata or live performance. I can see which tab and node you're looking at.</div>
        ) : conv.messages.map((m, i) => m.role === 'user' ? (
          <div key={i} className="msg user">{m.text}</div>
        ) : (
          <div key={i} className={`msg bot ${m.error ? 'err' : ''}`}>
            {!!m.tools?.length && <div className="tools">{m.tools.map(t => <span key={t}>⚙ {TOOL_LABEL[t] ?? t}</span>)}</div>}
            {m.text ? <Markdown source={m.text} /> : m.pending && <div className="typing"><span /><span /><span /></div>}
            {m.error && <div>{m.error}</div>}
            {m.seconds !== undefined && <div className="meta">{m.seconds} s</div>}
          </div>
        ))}
      </div>
      {conv.messages.length === 0 && (
        <div className="chat-suggest">
          {SUGGESTIONS.map(s => <button key={s} className="chip" onClick={() => ask(s)}>{s}</button>)}
        </div>
      )}
      <form className="chat-form" onSubmit={e => { e.preventDefault(); ask(input) }}>
        <textarea ref={inputRef} rows={2} value={input} onChange={e => setInput(e.target.value)}
          placeholder="Ask about Always On, patching, maintenance windows, security or performance…"
          onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); ask(input) } }} />
        <button className="primary" disabled={busy || !input.trim()}>Send</button>
      </form>
      <div className="chat-foot">Answers come from live Azure data via the sql-ha agent. Use a node's Actions to patch or fail over.</div>
    </section>
  )
}

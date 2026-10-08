import { useState } from 'react'
import { api } from '../../api/client'
import type { ActionResult } from '../../api/types'
import { Banner } from '../common/Card'

type ActionId = 'plan' | 'assess' | 'install' | 'failover'

interface ActionDef {
  id: ActionId
  label: string
  description: string
  write: boolean
  run: (confirm: boolean) => Promise<ActionResult>
}

interface ActionsPanelProps {
  machine: string
  instance?: string
  role?: string | null
  writeEnabled: boolean
  onChanged: () => void
}

function Summary({ result }: { result: ActionResult }) {
  const blockers = result.blockers ?? []
  const warnings = result.warnings ?? []
  return (
    <div className="action-result">
      {result.message && <p>{result.message}</p>}
      {result.reason && <p><b>{result.reason}</b></p>}
      {blockers.length > 0 && <Banner tone="bad"><b>Blocked:</b><ul>{blockers.map(b => <li key={b}>{b}</li>)}</ul></Banner>}
      {warnings.length > 0 && <Banner><ul>{warnings.map(w => <li key={w}>{w}</li>)}</ul></Banner>}
      {result.next_step && <p className="muted">{result.next_step}</p>}
      {result.operation_url && <p className="muted">Started. Azure operation is running; refresh in a few minutes.</p>}
      <details><summary>Raw response</summary><pre className="mono">{JSON.stringify(result, null, 2)}</pre></details>
    </div>
  )
}

/** Preview → confirm → execute for node-level actions. The backend enforces the AG safety rules. */
export function ActionsPanel({ machine, instance, role, writeEnabled, onChanged }: ActionsPanelProps) {
  const [active, setActive] = useState<ActionId | null>(null)
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<ActionResult | null>(null)
  const [result, setResult] = useState<ActionResult | null>(null)
  const [error, setError] = useState<string | null>(null)

  const actions: ActionDef[] = [
    { id: 'plan', label: 'Patch preflight', write: false, description: 'AG-safety check for patching this node now (read-only).',
      run: () => api.patchPlan(machine) },
    { id: 'assess', label: 'Run assessment', write: true, description: 'Scan for missing updates (no install, no reboot).',
      run: confirm => api.assess(machine, confirm) },
    { id: 'install', label: 'Install patches', write: true,
      description: role === 'PRIMARY' ? 'This node is the primary: fails over to a ready secondary first, then patches. May reboot.' : 'Install updates on this node. May reboot.',
      run: confirm => api.installPatches(machine, confirm, { failover_first: role === 'PRIMARY' }) },
    ...(instance && role === 'SECONDARY' ? [{ id: 'failover' as const, label: 'Fail over here', write: true,
      description: `Planned, no-data-loss failover making ${instance} the primary.`, run: (confirm: boolean) => api.failover(instance, confirm) }] : []),
  ]

  async function start(a: ActionDef) {
    setActive(a.id); setPreview(null); setResult(null); setError(null); setBusy(true)
    try {
      const r = await a.run(false)
      if (a.write) setPreview(r)
      else setResult(r)
    } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  async function confirm(a: ActionDef) {
    setBusy(true); setError(null)
    try {
      setResult(await a.run(true)); setPreview(null); onChanged()
    } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  const current = actions.find(a => a.id === active)
  const canConfirm = preview && preview.can_proceed !== false && !(preview.blockers?.length) && !preview.reason
    && !(preview.success === true && preview.executed === false)

  return (
    <div className="actions">
      <div className="action-buttons">
        {actions.map(a => (
          <button key={a.id} onClick={() => start(a)} disabled={busy} className={active === a.id ? 'active' : ''} title={a.description}>
            {a.label}
          </button>
        ))}
      </div>
      {!writeEnabled && <p className="muted small">Write actions are disabled (SQLHA_ENABLE_WRITE_ACTIONS). Previews still work.</p>}
      {current && <p className="muted">{current.description}</p>}
      {busy && <p className="muted"><span className="spin">⟳</span> Working… (failover and preflight can take up to a minute)</p>}
      {error && <Banner tone="bad">{error}</Banner>}
      {preview && current && (
        <>
          <Summary result={preview} />
          {canConfirm && (
            <div className="confirm-row">
              <button className="danger" onClick={() => confirm(current)} disabled={busy || !writeEnabled}>
                Confirm: {current.label.toLowerCase()} on {current.id === 'failover' ? instance : machine}
              </button>
              <button onClick={() => { setPreview(null); setActive(null) }} disabled={busy}>Cancel</button>
            </div>
          )}
        </>
      )}
      {result && <Summary result={result} />}
    </div>
  )
}

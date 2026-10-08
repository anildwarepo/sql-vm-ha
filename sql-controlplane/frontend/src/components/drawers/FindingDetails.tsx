import type { Finding } from '../../api/types'

const TAB_FOR: Record<string, string> = {
  availability: 'alwayson', patching: 'patching', maintenance: 'maintenance', security: 'security', connectivity: 'instances',
}

interface FindingDetailsProps {
  finding: Finding
  machines: string[]
  onOpenNode: (machine: string) => void
  onGoTab: (tab: string) => void
}

export function FindingDetails({ finding: f, machines, onOpenNode, onGoTab }: FindingDetailsProps) {
  const machine = machines.find(m => (f.resource ?? '').toLowerCase().includes(m.toLowerCase()))
  return (
    <>
      {f.detail && <p>{f.detail}</p>}
      {f.recommendation && (<><h3>Recommendation</h3><p>{f.recommendation}</p></>)}
      <h3>Resource</h3>
      <p>{f.resource ?? '—'}</p>
      <div className="action-buttons">
        {machine && <button onClick={() => onOpenNode(machine)}>Open {machine} ›</button>}
        <button onClick={() => onGoTab(TAB_FOR[f.category] ?? 'overview')}>Go to {f.category} ›</button>
      </div>
    </>
  )
}

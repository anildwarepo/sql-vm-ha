import { useMemo, useState } from 'react'
import type { Finding } from '../../api/types'
import { SEVERITIES, lc } from '../../utils/format'
import { Empty } from '../common/Card'
import { ChipGroup } from '../common/ChipGroup'
import { Pill } from '../common/Pill'

interface FindingListProps {
  findings: Finding[]
  query: string
  onSelect: (f: Finding) => void
}

/** Prioritized findings with severity and category filters. */
export function FindingList({ findings, query, onSelect }: FindingListProps) {
  const counts = useMemo(() => {
    const c: Record<string, number> = {}
    findings.forEach(f => { c[f.severity] = (c[f.severity] ?? 0) + 1 })
    return c
  }, [findings])
  const categories = useMemo(() => [...new Set(findings.map(f => f.category))].sort(), [findings])
  const [sevOn, setSevOn] = useState<string[]>([...SEVERITIES])
  const [cat, setCat] = useState('all')

  const q = lc(query)
  const list = findings.filter(f => sevOn.includes(f.severity) && (cat === 'all' || f.category === cat)
    && (!q || lc(JSON.stringify(f)).includes(q)))

  return (
    <>
      <div className="toolbar">
        <ChipGroup options={SEVERITIES.filter(s => counts[s]).map(s => ({ value: s, label: `${counts[s]} ${s}` }))}
          selected={sevOn} onToggle={s => setSevOn(p => (p.includes(s) ? p.filter(x => x !== s) : [...p, s]))} />
        <div className="spacer" />
        <ChipGroup options={['all', ...categories].map(c => ({ value: c, label: c }))} selected={[cat]} onToggle={setCat} />
      </div>
      {list.length ? list.map((f, i) => (
        <button key={`${f.title}-${i}`} className="finding" onClick={() => onSelect(f)}>
          <Pill tone={f.severity === 'critical' ? 'bad' : f.severity === 'medium' ? 'warn' : f.severity}>{f.severity}</Pill>
          <div className="finding-text">
            <div className="t">{f.title}</div>
            <div className="d">{f.category}{f.resource ? ` · ${f.resource}` : ''}{f.detail ? ` · ${f.detail}` : ''}</div>
          </div>
        </button>
      )) : <Empty>No findings match</Empty>}
    </>
  )
}

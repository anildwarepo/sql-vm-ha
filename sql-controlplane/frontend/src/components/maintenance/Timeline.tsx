import { useState } from 'react'
import type { MaintenanceConfiguration } from '../../api/types'
import { useNow } from '../../hooks/useNow'
import { fmt, hm, toDate } from '../../utils/format'
import { Empty } from '../common/Card'
import { ChipGroup } from '../common/ChipGroup'

const RANGES = [{ value: '2', label: '48 h' }, { value: '7', label: '7 d' }, { value: '28', label: '28 d' }]

/** Daily schedules are indistinguishable on a multi-week axis; zoom to 48 h when windows repeat within 2 days. */
function autoRange(configs: MaintenanceConfiguration[], fallback: number): number {
  const daily = configs.some(c => {
    const w = c.next_windows.filter(x => x.start_utc)
    return w.length > 1 && toDate(w[1].start_utc)!.getTime() - toDate(w[0].start_utc)!.getTime() < 2 * 864e5
  })
  return daily ? 2 : fallback
}

export function Timeline({ configurations, defaultDays }: { configurations: MaintenanceConfiguration[]; defaultDays: number }) {
  const configs = configurations.filter(c => c.next_windows.some(w => w.start_utc))
  const [days, setDays] = useState(() => autoRange(configs, defaultDays))
  const now = useNow(60000)
  if (!configs.length) return <Empty>No upcoming windows</Empty>

  const t0 = now, t1 = t0 + days * 864e5
  const pct = (t: number) => Math.max(0, Math.min(100, ((t - t0) / (t1 - t0)) * 100))
  const ticks: { t: number; label: string }[] = []
  if (days <= 2) {
    const h = new Date(t0)
    h.setMinutes(0, 0, 0)
    h.setHours(Math.ceil((h.getHours() + 1) / 6) * 6)
    for (let t = h.getTime(); t <= t1; t += 6 * 36e5) ticks.push({ t, label: new Date(t).toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' }) })
  } else {
    const step = Math.max(1, Math.ceil(days / 6))
    for (let i = 0; i <= days; i += step) {
      const t = t0 + i * 864e5
      ticks.push({ t, label: new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) })
    }
  }

  return (
    <div className="timeline">
      <div className="timeline-tools">
        <ChipGroup options={RANGES} selected={[String(days)]} onToggle={v => setDays(Number(v))} />
      </div>
      {configs.map(c => {
        const next = c.next_windows.find(w => w.start_utc)!
        return (
          <div key={c.id} className="tl-row">
            <div>
              <b>{c.target_node ?? c.name}</b>
              <div className="muted small">{c.name}{c.wave ? ` · wave ${c.wave}` : ''}</div>
              <div className="muted small">next {hm(next.start_utc)}–{hm(next.end_utc)} · {c.recur_every}</div>
            </div>
            <div className="tl-track">
              {c.next_windows.filter(w => w.start_utc && toDate(w.start_utc)!.getTime() < t1).map(w => {
                const s = toDate(w.start_utc)!.getTime(), e = toDate(w.end_utc)!.getTime()
                return (
                  <div key={w.start_utc} className={`tl-win ${w.in_progress ? 'live' : c.wave ? `wave${c.wave}` : ''}`}
                    style={{ left: `${pct(s)}%`, width: `${Math.max(0.6, pct(e) - pct(s))}%` }}
                    title={`${c.name}: ${fmt(w.start_utc)} → ${fmt(w.end_utc)}`} />
                )
              })}
              <div className="tl-now" />
            </div>
          </div>
        )
      })}
      <div className="tl-axis">
        <div />
        <div className="tl-ticks">{ticks.map(x => <span key={x.t} style={{ left: `${pct(x.t)}%` }}>{x.label}</span>)}</div>
      </div>
    </div>
  )
}

import type { ReactNode } from 'react'
import { tone } from '../../utils/format'

interface PillProps {
  children: ReactNode
  /** Tone class: ok | bad | high | warn | low | info. Derived from the text when omitted. */
  tone?: string
  title?: string
}

export function Pill({ children, tone: t, title }: PillProps) {
  return (
    <span className={`pill ${t ?? tone(children)}`} title={title}>
      <span className="dot" />
      {children}
    </span>
  )
}

export function BoolPill({ value, yes = 'Yes', no = 'No' }: { value: boolean | null | undefined; yes?: string; no?: string }) {
  if (value === null || value === undefined) return <Pill tone="info">n/a</Pill>
  return <Pill tone={value ? 'ok' : 'bad'}>{value ? yes : no}</Pill>
}

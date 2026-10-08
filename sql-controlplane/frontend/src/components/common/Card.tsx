import type { ReactNode } from 'react'

interface CardProps {
  title?: ReactNode
  actions?: ReactNode
  children: ReactNode
  className?: string
}

export function Card({ title, actions, children, className }: CardProps) {
  return (
    <section className={`card ${className ?? ''}`}>
      {title !== undefined && (
        <header className="card-head">
          <h2>{title}</h2>
          {actions && <div className="card-actions">{actions}</div>}
        </header>
      )}
      <div className="card-body">{children}</div>
    </section>
  )
}

export function KeyValueGrid({ items }: { items: Record<string, ReactNode> }) {
  return (
    <div className="kv-grid">
      {Object.entries(items).map(([k, v]) => (
        <div key={k}>
          <span>{k}</span>
          {v === true ? 'Yes' : v === false ? 'No' : v ?? '—'}
        </div>
      ))}
    </div>
  )
}

export function Banner({ tone = 'warn', children }: { tone?: 'warn' | 'info' | 'bad'; children: ReactNode }) {
  return <div className={`banner ${tone}`}>{children}</div>
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>
}

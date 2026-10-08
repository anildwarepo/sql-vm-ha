import { useEffect } from 'react'
import type { ReactNode } from 'react'

interface DrawerProps {
  open: boolean
  title: ReactNode
  subtitle?: ReactNode
  onClose: () => void
  children: ReactNode
}

export function Drawer({ open, title, subtitle, onClose, children }: DrawerProps) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  return (
    <>
      <div className={`drawer-backdrop ${open ? 'open' : ''}`} onClick={onClose} />
      <div className="drawer-clip">
        <aside className={`drawer ${open ? 'open' : ''}`} aria-hidden={!open}>
          <header className="drawer-head">
            <div>
              <h1>{title}</h1>
              {subtitle && <div className="sub">{subtitle}</div>}
            </div>
            <button className="icon" onClick={onClose} aria-label="Close">✕</button>
          </header>
          <div className="drawer-body">{open && children}</div>
        </aside>
      </div>
    </>
  )
}

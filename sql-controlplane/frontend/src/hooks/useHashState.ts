import { useCallback, useEffect, useState } from 'react'

export interface HashState {
  tab: string
  node: string | null
}

const parse = (): HashState => {
  const p = new URLSearchParams(window.location.hash.slice(1))
  return { tab: p.get('tab') ?? 'overview', node: p.get('node') }
}

/** Deep-linkable UI state in the URL hash: #tab=patching&node=SQL-VM-1 */
export function useHashState(): [HashState, (patch: Partial<HashState>) => void] {
  const [state, setState] = useState<HashState>(parse)

  useEffect(() => {
    const onHash = () => setState(parse())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const update = useCallback((patch: Partial<HashState>) => {
    setState(prev => {
      const next = { ...prev, ...patch }
      const p = new URLSearchParams()
      p.set('tab', next.tab)
      if (next.node) p.set('node', next.node)
      window.history.replaceState(null, '', `#${p.toString()}`)
      return next
    })
  }, [])

  return [state, update]
}

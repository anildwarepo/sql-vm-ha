import { Fragment, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { lc } from '../../utils/format'
import { Empty } from './Card'

export interface Column<T> {
  key: string
  title: string
  render?: (row: T) => ReactNode
  /** Value used for sorting; defaults to row[key]. */
  sortValue?: (row: T) => string | number | boolean | null | undefined
  className?: string
}

interface DataTableProps<T> {
  columns: Column<T>[]
  rows: T[]
  rowKey: (row: T, index: number) => string
  /** Global search text; rows whose JSON doesn't contain it are hidden. */
  query?: string
  filter?: (row: T) => boolean
  /** Expandable detail row (click to toggle). */
  expand?: (row: T) => ReactNode
  onRowClick?: (row: T) => void
  defaultSort?: { key: string; asc?: boolean }
  empty?: string
}

export function DataTable<T>({ columns, rows, rowKey, query, filter, expand, onRowClick, defaultSort, empty }: DataTableProps<T>) {
  const [sort, setSort] = useState<{ key: string; asc: boolean } | null>(
    defaultSort ? { key: defaultSort.key, asc: defaultSort.asc ?? true } : null)
  const [open, setOpen] = useState<Set<string>>(new Set())

  const visible = useMemo(() => {
    const q = lc(query)
    let out = rows.filter(r => (!filter || filter(r)) && (!q || lc(JSON.stringify(r)).includes(q)))
    if (sort) {
      const col = columns.find(c => c.key === sort.key)
      const val = col?.sortValue ?? ((r: T) => (r as Record<string, unknown>)[sort.key] as string)
      out = [...out].sort((a, b) => {
        const x = val(a) ?? '', y = val(b) ?? ''
        return (x > y ? 1 : x < y ? -1 : 0) * (sort.asc ? 1 : -1)
      })
    }
    return out
  }, [rows, query, filter, sort, columns])

  if (!visible.length) return <Empty>{empty ?? 'Nothing to show'}</Empty>
  const clickable = Boolean(expand || onRowClick)

  const toggleSort = (key: string) =>
    setSort(prev => ({ key, asc: prev?.key === key ? !prev.asc : true }))

  const onClick = (row: T, id: string) => {
    if (onRowClick) return onRowClick(row)
    setOpen(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            {columns.map(c => (
              <th key={c.key} onClick={() => toggleSort(c.key)}
                className={sort?.key === c.key ? `sorted ${sort.asc ? 'asc' : ''}` : ''}>
                {c.title}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {visible.map((row, i) => {
            const id = rowKey(row, i)
            return (
              <Fragment key={id}>
                <tr className={clickable ? 'click' : ''} onClick={clickable ? () => onClick(row, id) : undefined}>
                  {columns.map(c => (
                    <td key={c.key} className={c.className}>
                      {c.render ? c.render(row) : String((row as Record<string, unknown>)[c.key] ?? '')}
                    </td>
                  ))}
                </tr>
                {expand && open.has(id) && (
                  <tr className="detail"><td colSpan={columns.length}>{expand(row)}</td></tr>
                )}
              </Fragment>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

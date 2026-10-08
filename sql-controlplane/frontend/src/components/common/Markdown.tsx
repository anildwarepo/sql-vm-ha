import { Fragment } from 'react'
import type { ReactNode } from 'react'

// A small, safe Markdown renderer for chat answers: React escapes all text, so no HTML is ever injected.
// Supports paragraphs, headings, bullet/numbered lists, tables, fenced code, `code`, **bold** and [links](https://...).

function inline(text: string, keyPrefix: string): ReactNode[] {
  const out: ReactNode[] = []
  const re = /(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\(https?:\/\/[^)\s]+\))/g
  let last = 0
  let m: RegExpExecArray | null
  let i = 0
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index))
    const tok = m[0]
    const key = `${keyPrefix}-${i++}`
    if (tok.startsWith('`')) out.push(<code key={key}>{tok.slice(1, -1)}</code>)
    else if (tok.startsWith('**')) out.push(<b key={key}>{tok.slice(2, -2)}</b>)
    else {
      const lm = /^\[([^\]]+)\]\((.+)\)$/.exec(tok)!
      out.push(<a key={key} href={lm[2]} target="_blank" rel="noopener noreferrer">{lm[1]}</a>)
    }
    last = m.index + tok.length
  }
  if (last < text.length) out.push(text.slice(last))
  return out
}

const cells = (line: string) => line.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim())
const isList = (l: string) => /^\s*([-*]|\d+\.)\s+/.test(l)
const isTableStart = (lines: string[], i: number) => /^\s*\|/.test(lines[i]) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])

export function Markdown({ source }: { source: string }) {
  const lines = source.replace(/\r/g, '').split('\n')
  const blocks: ReactNode[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    const k = `b${i}`
    if (/^```/.test(line)) {
      const code: string[] = []
      i++
      while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++])
      i++
      blocks.push(<pre key={k} className="mono">{code.join('\n')}</pre>)
    } else if (isTableStart(lines, i)) {
      const head = cells(line)
      i += 2
      const body: string[][] = []
      while (i < lines.length && /^\s*\|/.test(lines[i])) body.push(cells(lines[i++]))
      blocks.push(
        <div key={k} className="table-wrap">
          <table>
            <thead><tr>{head.map((c, j) => <th key={j}>{inline(c, `${k}h${j}`)}</th>)}</tr></thead>
            <tbody>{body.map((r, ri) => <tr key={ri}>{r.map((c, j) => <td key={j}>{inline(c, `${k}r${ri}c${j}`)}</td>)}</tr>)}</tbody>
          </table>
        </div>)
    } else if (/^#{1,4}\s+/.test(line)) {
      blocks.push(<h4 key={k}>{inline(line.replace(/^#{1,4}\s+/, ''), k)}</h4>)
      i++
    } else if (isList(line)) {
      const ordered = /^\s*\d+\./.test(line)
      const items: string[] = []
      while (i < lines.length && isList(lines[i])) items.push(lines[i++].replace(/^\s*([-*]|\d+\.)\s+/, ''))
      const children = items.map((t, j) => <li key={j}>{inline(t, `${k}l${j}`)}</li>)
      blocks.push(ordered ? <ol key={k}>{children}</ol> : <ul key={k}>{children}</ul>)
    } else if (!line.trim()) {
      i++
    } else {
      const para: string[] = []
      while (i < lines.length && lines[i].trim() && !/^(```|#{1,4}\s)/.test(lines[i]) && !isList(lines[i]) && !isTableStart(lines, i)) {
        para.push(lines[i++])
      }
      blocks.push(<p key={k}>{para.map((p, j) => <Fragment key={j}>{j > 0 && <br />}{inline(p, `${k}p${j}`)}</Fragment>)}</p>)
    }
  }
  return <>{blocks}</>
}

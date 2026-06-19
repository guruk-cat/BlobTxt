import { hoverTooltip } from '@codemirror/view'

// Footnote utilities (shared by the hover tooltip, the inline mark decorations,
// and the arrange command)

/*
  Inline reference regex. FootnoteReference is not a dedicated node type in the
  lezer GFM parser, so references are matched textually. Defined here as the
  single source so the decoration plugin and the arrange command share it; both
  reset lastIndex before use since it is a /g regex.
*/
export const fnRefRe = /\[\^([^\]]+)\](?!\()/g

/*
  A footnote definition is a line "[^label]: text" optionally followed by
  indented continuation lines (GFM syntax). The definition text after "]:" is
  captured in group 2.
*/
const fnDefRe = /^\[\^([^\]]+)\]:[ \t]?(.*)$/

/*
  Collects every footnote definition block from an array of document lines.
  Returns the definitions as a Map from label to an array of content lines (the
  text after "]:" plus any de-indented continuation lines), and a Set of every
  line index belonging to a definition block so callers can strip them from the
  body when rewriting the document.
*/
export function collectFootnoteDefs(lines) {
  const defs = new Map()
  const defLineIdx = new Set()
  for (let i = 0; i < lines.length; i++) {
    const m = fnDefRe.exec(lines[i])
    if (!m) continue
    const block = [m[2]]
    defLineIdx.add(i)
    // Absorb following indented lines as continuation of this definition.
    let j = i + 1
    while (j < lines.length && /^[ \t]+\S/.test(lines[j])) {
      block.push(lines[j].replace(/^[ \t]+/, ''))
      defLineIdx.add(j)
      j++
    }
    defs.set(m[1], block)
    i = j - 1
  }
  return { defs, defLineIdx }
}

// Returns the definition text for a label as a single flattened string, or null.
function lookupFootnoteDef(state, label) {
  const { defs } = collectFootnoteDefs(state.doc.toString().split('\n'))
  const block = defs.get(label)
  return block ? block.join(' ').trim() : null
}

// Footnote hover tooltip. A hoverTooltip() source: resolves a hovered position
// to a footnote reference on its line and builds the definition tooltip, or
// returns null. hoverTooltip handles the hover delay, the on-content hit test
// (which rejects hovers landing in the line's tall vertical padding), and
// hide-on-leave/change; the box is themed via .cm-footnote-tooltip.
function footnoteTipAt(view, pos) {
  const line = view.state.doc.lineAt(pos)
  if (fnDefRe.test(line.text)) return null  // not on a definition line
  fnRefRe.lastIndex = 0
  let m
  while ((m = fnRefRe.exec(line.text)) !== null) {
    const start = line.from + m.index
    const end   = start + m[0].length
    if (pos < start || pos > end) continue
    const def = lookupFootnoteDef(view.state, m[1])
    if (!def) return null
    return {
      pos: start,
      end,
      above: true,
      create() {
        const dom = document.createElement('div')
        dom.className = 'cm-footnote-tooltip'
        dom.textContent = def
        return { dom }
      },
    }
  }
  return null
}

export const footnoteHover = hoverTooltip(footnoteTipAt, { hideOnChange: true })

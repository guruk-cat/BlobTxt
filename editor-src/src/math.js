import { ViewPlugin, Decoration, hoverTooltip } from '@codemirror/view'
import katex from 'katex'

// LaTeX math ($…$ inline, $$…$$ block). Math is not a node type in the lezer
// GFM parser, so — exactly like footnote references (see footnotes.js) — it is
// matched textually, and the same regex drives both the mark decorations and
// the hover tooltip.

// The block $$…$$ alternative comes first (and may span lines via [\s\S]) so it
// wins over inline $. Inline allows spaces inside ($ E = mc^2 $) but rejects
// currency: a closing '$' immediately followed by a digit isn't a delimiter, so
// "$5 and $10" stays prose (the markdown-it/remark-math heuristic). The opening
// and closing '$' are each guarded against '$' so neither half of a '$$' is
// mistaken for inline. Group 1 is block content, group 2 is inline content.

// Heuristic, not a real TeX scanner; odd prose like "cost $ then $" can 
// false-match; switch to a parser extension if that ever bites.
export const mathRe = /\$\$([\s\S]*?)\$\$|(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)(?!\d)/g

// Splits a match into the delimiter length and the expression. Block uses '$$'.
function partsOf(m) {
  const display = m[0].startsWith('$$')
  return { display, delim: display ? 2 : 1, expr: (display ? m[1] : m[2]) }
}

// Mark decorations: delimiters in --meta-indication, the expression in
// --text-body (a CSS override that also neutralizes any stray markdown styling
// inside the math, e.g. $*x*$). Mirrors buildMarkDecorations in decorations.js.
function buildMathDecorations(view) {
  const decos = []
  const doc = view.state.doc
  for (const { from, to } of view.visibleRanges) {
    const text = doc.sliceString(from, to)
    mathRe.lastIndex = 0
    let m
    while ((m = mathRe.exec(text)) !== null) {
      const { delim } = partsOf(m)
      const start = from + m.index
      const end   = start + m[0].length
      decos.push(Decoration.mark({ class: 'cm-math-mark' }).range(start, start + delim))
      if (end - delim > start + delim)
        decos.push(Decoration.mark({ class: 'cm-math-expr' }).range(start + delim, end - delim))
      decos.push(Decoration.mark({ class: 'cm-math-mark' }).range(end - delim, end))
    }
  }
  decos.sort((a, b) => a.from - b.from || a.startSide - b.startSide)
  return Decoration.set(decos)
}

export const mathDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildMathDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildMathDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

// Hover tooltip: KaTeX-rendered math, like the footnote tooltip. Scans the whole
// document (cheap, hover is infrequent) so multi-line $$…$$ blocks resolve too.
function mathTipAt(view, pos) {
  const text = view.state.doc.toString()
  mathRe.lastIndex = 0
  let m
  while ((m = mathRe.exec(text)) !== null) {
    const start = m.index
    const end   = start + m[0].length
    if (pos < start || pos > end) continue
    const { display, expr } = partsOf(m)
    const trimmed = expr.trim()
    if (!trimmed) return null
    // throwOnError:false renders errors as inline red text instead of throwing.
    const html = katex.renderToString(trimmed, { displayMode: display, throwOnError: false })
    return {
      pos: start,
      end,
      above: true,
      create() {
        const dom = document.createElement('div')
        dom.className = 'cm-math-tooltip'
        dom.innerHTML = html
        return { dom }
      },
    }
  }
  return null
}

export const mathHover = hoverTooltip(mathTipAt, { hideOnChange: true })

import { ViewPlugin, Decoration } from '@codemirror/view'

// Pandoc citations ([@key], [@key, p. 5], [see @k1; @k2]). Like math and
// footnote refs, citations aren't a node type in the GFM parser, so they're
// matched textually and the regex drives the mark decorations.

// A bracket pair containing an '@' — pandoc's own trigger for citation mode, so
// this automatically skips [^fn] refs, [text](url) links, ![alt], and plain
// [bracketed text], none of which carry an '@'.
export const citeRe = /\[[^\]]*@[^\]]*\]/g

// The cite key inside the bracket. '@' then a word-char start and a run of
// word-chars/':'/'.'/'-'. ponytail: editor-only key charset; widen to the full
// pandoc set (#$%&+?<>~/) if real keys ever render half-highlighted.
const keyRe = /@[\w][\w:.\-]*/g

// Brackets/'@' recede to --text-muted, the key takes --meta-indication, and the
// rest of the bracket interior takes --text-body. The body marks matter because
// [@key] can parse as a shortcut link; the override strips that stray styling,
// mirroring cm-math-expr in math.js.
function buildCiteDecorations(view) {
  const decos = []
  const doc = view.state.doc
  for (const { from, to } of view.visibleRanges) {
    const text = doc.sliceString(from, to)
    citeRe.lastIndex = 0
    let m
    while ((m = citeRe.exec(text)) !== null) {
      const start = from + m.index
      const end   = start + m[0].length
      decos.push(mark('cm-cite-bracket', start, start + 1))   // opening '['
      // Walk the interior, splitting keys out from the body text between them.
      const inner = m[0].slice(1, -1)
      const innerStart = start + 1
      let cursor = innerStart
      keyRe.lastIndex = 0
      let k
      while ((k = keyRe.exec(inner)) !== null) {
        const kStart = innerStart + k.index
        const kEnd   = kStart + k[0].length
        if (kStart > cursor) decos.push(mark('cm-cite-body', cursor, kStart))
        decos.push(mark('cm-cite-bracket', kStart, kStart + 1))  // the '@'
        decos.push(mark('cm-cite-key', kStart + 1, kEnd))        // the key
        cursor = kEnd
      }
      if (end - 1 > cursor) decos.push(mark('cm-cite-body', cursor, end - 1))
      decos.push(mark('cm-cite-bracket', end - 1, end))          // closing ']'
    }
  }
  decos.sort((a, b) => a.from - b.from || a.startSide - b.startSide)
  return Decoration.set(decos)
}

const mark = (cls, from, to) => Decoration.mark({ class: cls }).range(from, to)

export const citeDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildCiteDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildCiteDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

import { ViewPlugin, Decoration } from '@codemirror/view'
import { syntaxTree } from '@codemirror/language'
import { fnRefRe } from './footnotes.js'

// Line decoration plugin

// Attaches CSS classes to whole lines based on syntax tree node types.
// Token-level styles are handled by HighlightStyle; line-level layout
// (heading size, blockquote indent) lives in editorBaseTheme and fontCompartment.
function buildLineDecorations(view) {
  const lineClasses = new Map()
  const doc = view.state.doc

  function addCls(pos, cls) {
    const from = doc.lineAt(pos).from
    if (!lineClasses.has(from)) lineClasses.set(from, new Set())
    lineClasses.get(from).add(cls)
  }

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(view.state).iterate({
      from,
      to,
      enter(node) {
        const n = node.name
        if (n === 'ATXHeading1') { addCls(node.from, 'cm-md-h1'); return false }
        if (n === 'ATXHeading2') { addCls(node.from, 'cm-md-h2'); return false }
        if (n === 'ATXHeading3') { addCls(node.from, 'cm-md-h3'); return false }
        if (n === 'ATXHeading4') { addCls(node.from, 'cm-md-h4'); return false }
        if (n === 'ATXHeading5') { addCls(node.from, 'cm-md-h5'); return false }
        if (n === 'QuoteMark')   { addCls(node.from, 'cm-md-blockquote') }
      },
    })

    // Footnote definitions ([^label]: ...) are not a node type in the lezer
    // markdown parser, so we detect them with a per-line regex pass instead.
    let pos = from
    while (pos <= to) {
      const line = doc.lineAt(pos)
      if (/^\[\^[^\]]+\]:/.test(line.text)) addCls(line.from, 'cm-md-footnote-def')
      pos = line.to + 1
    }
  }

  const decos = []
  for (const [from, classes] of lineClasses) {
    decos.push(Decoration.line({ class: [...classes].join(' ') }).range(from))
  }
  decos.sort((a, b) => a.from - b.from)
  return Decoration.set(decos)
}

export const headingLineDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildLineDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildLineDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

// Inline mark decoration plugin

// Applies sub-token styling that HighlightStyle cannot express — specifically,
// coloring different parts of a footnote reference [^label] differently.
// References are detected by scanning visible text with fnRefRe (from footnotes.js).
function buildMarkDecorations(view) {
  const decos = []
  const doc = view.state.doc
  for (const { from, to } of view.visibleRanges) {
    const text = doc.sliceString(from, to)
    fnRefRe.lastIndex = 0
    let m
    while ((m = fnRefRe.exec(text)) !== null) {
      const start = from + m.index
      const end   = start + m[0].length
      // [^ → text-muted, label → meta-indication, ] → text-muted
      decos.push(Decoration.mark({ class: 'cm-fn-mark'  }).range(start,     start + 2))
      decos.push(Decoration.mark({ class: 'cm-fn-label' }).range(start + 2, end - 1))
      decos.push(Decoration.mark({ class: 'cm-fn-mark'  }).range(end - 1,   end))
    }
  }
  decos.sort((a, b) => a.from - b.from || a.startSide - b.startSide)
  return Decoration.set(decos)
}

export const inlineMarkDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildMarkDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildMarkDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

// Link decoration plugin

// Marks the URL node with cm-blob-link, the same range the Cmd+click handler
// resolves, so the hover affordance matches exactly what is clickable.
function buildLinkDecorations(view) {
  const decos = []
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(view.state).iterate({
      from, to,
      enter(node) {
        if (node.name === 'URL')
          decos.push(Decoration.mark({ class: 'cm-blob-link' }).range(node.from, node.to))
      },
    })
  }
  return Decoration.set(decos)
}

export const linkDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildLinkDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildLinkDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

// Cmd-held tracking plugin

// Reads metaKey primarily from mousemove because macOS keyup for the Cmd key is
// unreliable; keydown/keyup and window blur are backups.
export const cmdKeyTracking = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.view = view
      this.sync = e => view.dom.classList.toggle('cmd-held', e.metaKey)
      this.clear = () => view.dom.classList.remove('cmd-held')
      window.addEventListener('keydown', this.sync)
      window.addEventListener('keyup', this.sync)
      view.dom.addEventListener('mousemove', this.sync)
      window.addEventListener('blur', this.clear)
    }
    destroy() {
      window.removeEventListener('keydown', this.sync)
      window.removeEventListener('keyup', this.sync)
      this.view.dom.removeEventListener('mousemove', this.sync)
      window.removeEventListener('blur', this.clear)
    }
  }
)

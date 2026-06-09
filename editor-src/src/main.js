import { EditorView, keymap, ViewPlugin, Decoration } from '@codemirror/view'
import { EditorState, Transaction } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { GFM } from '@lezer/markdown'
import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { tags } from '@lezer/highlight'

// Swift bridge

function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

// Module-level state 

// Suppresses the documentChanged post during programmatic content replacement
// (setContent). view.dispatch() is synchronous, so this flag is set and cleared
// within the same call stack before any user-triggered update can fire.
let suppressDocChanged = false
let autoScrollMode = 'regular'

// Syntax highlighting

// Token-level colors and weights. Font sizes for headings are NOT set here —
// they are set by Swift's applyEditorStyle on .cm-line.cm-md-h1/h2/h3 so they
// scale correctly when the user changes the font size preference.

const highlightStyle = HighlightStyle.define([
  { tag: tags.processingInstruction, color: 'var(--text-muted)' },
  { tag: tags.heading1,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.heading2,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.heading3,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.strong,    fontWeight: 'bold' },
  { tag: tags.emphasis,  fontStyle: 'italic' },
  { tag: tags.url,       color: 'var(--meta-indication)' },
  { tag: tags.labelName, color: 'var(--meta-indication)' },
])

// Line decoration plugin

// Attaches CSS classes to whole lines based on syntax tree node types.
// Token-level styles are handled above; line-level layout (heading size,
// blockquote border, footnote definition indent) lives in style.css and in
// Swift's applyEditorStyle.

function buildLineDecorations(view) {
  const lineClasses = new Map()
  const doc = view.state.doc

  function addCls(pos, cls) {
    const from = doc.lineAt(pos).from
    if (!lineClasses.has(from)) lineClasses.set(from, new Set())
    lineClasses.get(from).add(cls)
  }

  for (const { from, to } of view.visibleRanges) {
    // Heading and blockquote classes come from the syntax tree.
    syntaxTree(view.state).iterate({
      from,
      to,
      enter(node) {
        const n = node.name
        if (n === 'ATXHeading1') { addCls(node.from, 'cm-md-h1'); return false }
        if (n === 'ATXHeading2') { addCls(node.from, 'cm-md-h2'); return false }
        if (n === 'ATXHeading3') { addCls(node.from, 'cm-md-h3'); return false }
        if (n === 'QuoteMark') { addCls(node.from, 'cm-md-blockquote') }
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

const headingLineDecorations = ViewPlugin.fromClass(
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

// Applies sub-token styling that HighlightStyle can't express — specifically,
// coloring different parts of a footnote reference [^label] differently.

// Decoration.mark() wraps a character range in a <span> with a CSS class.
// Footnote references ([^label]) are not represented as a dedicated node type
// in the lezer markdown parser, so we detect them by scanning the visible text
// with a regex and apply mark decorations directly on the character ranges.
const fnRefRe = /\[\^([^\]]+)\](?!\()/g

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
      // If preceded by '!', the parser tags '!' as processingInstruction
      // (image syntax), which HighlightStyle colors text-muted. An inline style
      // overrides the HighlightStyle class regardless of CSS cascade order.
      if (m.index > 0 && text[m.index - 1] === '!') {
        decos.push(Decoration.mark({ attributes: { style: 'color: var(--text-body)' } }).range(start - 1, start))
      }
      // [^ → text-muted, label → meta-indication, ] → text-muted
      decos.push(Decoration.mark({ class: 'cm-fn-mark'  }).range(start, start + 2))
      decos.push(Decoration.mark({ class: 'cm-fn-label' }).range(start + 2, end - 1))
      decos.push(Decoration.mark({ class: 'cm-fn-mark'  }).range(end - 1, end))
    }
  }
  decos.sort((a, b) => a.from - b.from || a.startSide - b.startSide)
  return Decoration.set(decos)
}

const inlineMarkDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildMarkDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildMarkDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

// Centered scroll 
//
// Keeps the cursor vertically centered when it moves past the midpoint of the
// editor. Only active when autoScrollMode is 'centered'.

function doCenteredScroll() {
  if (autoScrollMode !== 'centered') return
  const sel = window.getSelection()
  if (!sel || sel.rangeCount === 0) return
  const range = sel.getRangeAt(0)
  const rect  = range.getBoundingClientRect()
  if (rect.height === 0) return
  const ed            = document.getElementById('editor')
  const edRect        = ed.getBoundingClientRect()
  const cursorCenterY = rect.top + rect.height / 2
  const edCenterY     = edRect.top + ed.clientHeight / 2
  if (cursorCenterY <= edCenterY) return
  const target = ed.scrollTop + (cursorCenterY - edCenterY)
  ed.scrollTo({ top: Math.max(0, target), behavior: 'smooth' })
}

// Editor initialization

const view = new EditorView({
  state: EditorState.create({
    doc: '',
    extensions: [
      markdown({ extensions: [GFM] }),
      syntaxHighlighting(highlightStyle),
      headingLineDecorations,
      inlineMarkDecorations,
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap]),
      EditorView.lineWrapping,
      EditorView.updateListener.of(update => {
        if (update.docChanged && !suppressDocChanged) {
          post({ type: 'documentChanged' })
          requestAnimationFrame(doCenteredScroll)
        }
      }),
      EditorView.domEventHandlers({
        // ⌘+click: resolve the click position to a URL node in the syntax tree
        // and open it in the system browser. CodeMirror renders links as styled
        // spans (no <a> elements), so we can't rely on event.target.closest('a').
        click(event, v) {
          if (!event.metaKey) return false
          const pos = v.posAtCoords({ x: event.clientX, y: event.clientY })
          if (pos === null) return false
          let node = syntaxTree(v.state).resolve(pos, 1)
          while (node) {
            if (node.name === 'URL') {
              let url = v.state.doc.sliceString(node.from, node.to)
              if (url.startsWith('<') && url.endsWith('>')) url = url.slice(1, -1)
              post({ type: 'openURL', url })
              event.preventDefault()
              return true
            }
            node = node.parent
          }
          return false
        },
      }),
    ],
  }),
  parent: document.getElementById('editor'),
})

post({ type: 'editorReady' })

// Scroll position tracking → Swift 

let scrollTimer = null
const edEl = document.getElementById('editor')
edEl.addEventListener('scroll', () => {
  clearTimeout(scrollTimer)
  scrollTimer = setTimeout(() => {
    post({ type: 'scrollPositionChanged', scrollTop: Math.round(edEl.scrollTop) })
  }, 300)
})

// window.editorBridge — called from Swift via evaluateJavaScript

window.editorBridge = {
  setContent(markdown) {
    suppressDocChanged = true
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: markdown || '' },
      annotations: Transaction.addToHistory.of(false),
    })
    suppressDocChanged = false
  },

  getContent() {
    return view.state.doc.toString()
  },

  setAutoScrollMode(m) {
    autoScrollMode = m
    const ed = document.getElementById('editor')
    ed.style.paddingBottom = m === 'centered' ? '50vh' : ''
  },

  setFocusMode(enabled) {
    document.body.classList.toggle('focus-mode', enabled)
  },

  setFocusModeCustomizations(enabled, floating, dimness, blur) {
    document.body.classList.toggle('focus-custom', enabled)
    document.body.classList.toggle('floating', enabled && floating)
    if (enabled) {
      document.documentElement.style.setProperty('--focus-dimness', dimness)
      document.documentElement.style.setProperty('--focus-blur', blur + 'px')
    }
  },

  setFocusWallpaper(dataURL) {
    document.documentElement.style.setProperty(
      '--focus-wallpaper',
      dataURL ? `url(${dataURL})` : 'none'
    )
  },
}

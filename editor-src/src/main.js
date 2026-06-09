import { EditorView, keymap, ViewPlugin, Decoration } from '@codemirror/view'
import { EditorState, Transaction } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { GFM } from '@lezer/markdown'
import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { tags } from '@lezer/highlight'

// ── Swift bridge ──────────────────────────────────────────────────────────────

function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

// ── Module-level state ────────────────────────────────────────────────────────

// Suppresses the documentChanged post during programmatic content replacement
// (setContent). view.dispatch() is synchronous, so this flag is set and cleared
// within the same call stack before any user-triggered update can fire.
let suppressDocChanged = false
let autoScrollMode = 'regular'

// ── Syntax highlighting ───────────────────────────────────────────────────────
//
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
  { tag: tags.link,      color: 'var(--text-body)' },
  { tag: tags.url,       color: 'var(--meta-indication)' },
  { tag: tags.labelName, color: 'var(--meta-indication)' },
])

// ── Line decoration plugin ────────────────────────────────────────────────────
//
// Attaches CSS classes to whole lines based on syntax tree node types.
// Token-level styles are handled above; line-level layout (heading size,
// blockquote border, footnote definition indent) lives in style.css and in
// Swift's applyEditorStyle.

function buildLineDecorations(view) {
  const lineClasses = new Map()

  function addCls(pos, cls) {
    const from = view.state.doc.lineAt(pos).from
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
        if (n === 'BlockquotePrefix') { addCls(node.from, 'cm-md-blockquote') }
        if (n === 'FootnoteDefinition') {
          const doc = view.state.doc
          const startLine = doc.lineAt(node.from).number
          const endLine   = doc.lineAt(node.to).number
          for (let ln = startLine; ln <= endLine; ln++) {
            addCls(doc.line(ln).from, 'cm-md-footnote-def')
          }
          return false
        }
      },
    })
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

// ── Centered scroll ───────────────────────────────────────────────────────────
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

// ── Editor initialization ─────────────────────────────────────────────────────

const view = new EditorView({
  state: EditorState.create({
    doc: '',
    extensions: [
      markdown({ extensions: [GFM] }),
      syntaxHighlighting(highlightStyle),
      headingLineDecorations,
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

// ── Scroll position tracking → Swift ─────────────────────────────────────────

let scrollTimer = null
const edEl = document.getElementById('editor')
edEl.addEventListener('scroll', () => {
  clearTimeout(scrollTimer)
  scrollTimer = setTimeout(() => {
    post({ type: 'scrollPositionChanged', scrollTop: Math.round(edEl.scrollTop) })
  }, 300)
})

// ── window.editorBridge — called from Swift via evaluateJavaScript ────────────

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

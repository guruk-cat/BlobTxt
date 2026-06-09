import { EditorView, keymap, ViewPlugin, Decoration } from '@codemirror/view'
import { EditorState, Transaction, Compartment } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { GFM } from '@lezer/markdown'
import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { tags } from '@lezer/highlight'
import { search, openSearchPanel, closeSearchPanel, searchPanelOpen, searchKeymap } from '@codemirror/search'

// Swift bridge communication
function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

// Module-level state

// Suppresses the documentChanged post during programmatic content replacement.
// view.dispatch() is synchronous, so this flag is set and cleared within the
// same call stack before any user-triggered update can fire.
let suppressDocChanged = false

// Font state is mirrored here so that partial updateConfig calls (e.g., only
// fontSize changes) can correctly rebuild the combined font theme.
let currentFontSize   = 16
let currentFontFamily = 'Menlo'

// Autoscroll mode does not need a CM compartment — it only affects JS logic in
// doCenteredScroll and a CSS property on #editor.
let autoScrollMode = 'regular'

// Compartments

const fontCompartment = new Compartment()

// Compartment extension builders

function fontFamilyCSS(family) {
  if (family === 'Palatino') return 'Palatino, "Palatino Linotype", serif'
  return 'Menlo, Consolas, "Courier New", monospace'
}

/*
  Builds an EditorView.theme() extension for the current font settings.
  EditorView.theme() scopes rules to the editor instance via a generated
  class, so these rules correctly override the static defaults in style.css.
*/
function buildFontTheme(fontSize, fontFamily) {
  const size    = fontSize   || 16
  const family  = fontFamilyCSS(fontFamily || 'Menlo')
  const maxWidth = Math.round(820 * size / 20)
  const x = Math.round(size)
  return EditorView.theme({
    '.cm-content': { fontFamily: family, fontSize: `${x}px` },
    '.cm-scroller': { maxWidth: `${maxWidth}px` },
    '.cm-line.cm-md-h1': { fontSize: `${Math.round(x * 2.0)}px`, lineHeight: '1.4' },
    '.cm-line.cm-md-h2': { fontSize: `${Math.round(x * 1.6)}px`, lineHeight: '1.4' },
    '.cm-line.cm-md-h3': { fontSize: `${Math.round(x * 1.3)}px`, lineHeight: '1.4' },
  })
}

// Lezer parser extension — footnote exclamation fix

/*
  When a sentence ends with '!' immediately before a footnote reference —
  e.g. "Hey there![^ref]" — the GFM Image parser sees '![' and creates an Image
  node even though there is no trailing '(url)'. That Image node contains a
  LinkMark element covering '![', which Lezer tags as processingInstruction.
  HighlightStyle applies text-muted color to processingInstruction, and because
  HighlightStyle spans end up as the inner DOM span, they win over any class or
  attribute override applied from outside.

  Fix: run a parseInline handler BEFORE the Image parser. When it sees '!'
  followed by '[^...]' with no '(' after ']', it consumes '!' as plain text
  (returns pos + 1 without adding any element). The Image parser never fires,
  no LinkMark node is created, and '!' renders as body text. The '[^ref]' that
  follows is then processed by the Link parser and colored by inlineMarkDecorations.
*/
const footnoteImageFix = {
  parseInline: [{
    name: 'FootnoteImageFix',
    before: 'Image',
    parse(cx, next, pos) {
      if (next !== 33) return -1               // not '!'
      if (cx.char(pos + 1) !== 91) return -1  // not '['
      if (cx.char(pos + 2) !== 94) return -1  // not '^' — leave normal images alone

      // Scan forward to find ']', then check whether '(' follows it.
      for (let i = pos + 3; i < cx.end; i++) {
        const c = cx.char(i)
        if (c === 93) {                        // ']'
          if (cx.char(i + 1) === 40) return -1  // '(' follows → real image, let Image handle it
          // No '(' — consume '!' as plain text, preventing the Image parser from firing.
          return pos + 1
        }
        if (c === 91 || c === 10) return -1   // '[' or newline — malformed, bail out
      }
      return -1  // no ']' found
    },
  }],
}

// Syntax highlighting

// Token-level colors and weights. Heading font sizes are NOT set here because
// they scale with the user's font size preference and must change together with
// .cm-content — both are handled by the fontCompartment theme instead.
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
// Token-level styles are handled by HighlightStyle above; line-level layout
// (heading size, blockquote indent) lives in style.css and the fontCompartment.
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

// Applies sub-token styling that HighlightStyle cannot express — specifically,
// coloring different parts of a footnote reference [^label] differently.
// FootnoteReference is not a dedicated node type in the lezer GFM parser, so
// references are detected by scanning visible text with a regex.
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
      // [^ → text-muted, label → meta-indication, ] → text-muted
      decos.push(Decoration.mark({ class: 'cm-fn-mark'  }).range(start,     start + 2))
      decos.push(Decoration.mark({ class: 'cm-fn-label' }).range(start + 2, end - 1))
      decos.push(Decoration.mark({ class: 'cm-fn-mark'  }).range(end - 1,   end))
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

// Keeps the cursor vertically centered when it moves past the midpoint of the
// editor. Only active when autoScrollMode is 'centered'.
function doCenteredScroll() {
  if (autoScrollMode !== 'centered') return
  const sel = window.getSelection()
  if (!sel || sel.rangeCount === 0) return
  const range = sel.getRangeAt(0)
  const rect  = range.getBoundingClientRect()
  if (rect.height === 0) return
  const ed        = document.getElementById('editor')
  const edRect    = ed.getBoundingClientRect()
  const cursorY   = rect.top + rect.height / 2
  const edCenterY = edRect.top + ed.clientHeight / 2
  if (cursorY <= edCenterY) return
  ed.scrollTo({ top: Math.max(0, ed.scrollTop + (cursorY - edCenterY)), behavior: 'smooth' })
}

// Editor initialization

const view = new EditorView({
  state: EditorState.create({
    doc: '',
    extensions: [
      markdown({ extensions: [footnoteImageFix, GFM] }),
      syntaxHighlighting(highlightStyle),
      headingLineDecorations,
      inlineMarkDecorations,
      history(),
      search({ top: true }),
      keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
      EditorView.lineWrapping,
      fontCompartment.of(buildFontTheme(16, 'Menlo')),
      EditorView.updateListener.of(update => {
        if (update.docChanged && !suppressDocChanged) {
          post({ type: 'documentChanged' })
          requestAnimationFrame(doCenteredScroll)
        }
        // Notify Swift whenever the search panel opens or closes, including when
        // the user clicks the panel's × button (which CM handles internally).
        const wasOpen = searchPanelOpen(update.startState)
        const isOpen  = searchPanelOpen(update.state)
        if (isOpen !== wasOpen) {
          post({ type: isOpen ? 'searchPanelOpened' : 'searchPanelClosed' })
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

// Config application helpers

/*
  Builds compartment reconfigure effects from a config/patch object.
  Only rebuilds compartments whose keys appear in the object.
  The font compartment needs both size and family to build its theme, so
  currentFontSize/currentFontFamily are kept in sync here.
*/
function buildCompartmentEffects(config) {
  const effects = []
  if ('fontSize' in config || 'fontFamily' in config) {
    if ('fontSize'   in config) currentFontSize   = config.fontSize
    if ('fontFamily' in config) currentFontFamily = config.fontFamily
    effects.push(fontCompartment.reconfigure(buildFontTheme(currentFontSize, currentFontFamily)))
  }
  return effects
}

/*
  Applies DOM and CSS changes that live outside CodeMirror's extension system:
  autoscroll padding, focus mode body classes, CSS variables, and the
  ::selection color injected via a style element.
*/
function applyConfigToDOM(config) {
  if ('autoscroll' in config) {
    autoScrollMode = config.autoscroll
    const ed = document.getElementById('editor')
    if (ed) ed.style.paddingBottom = config.autoscroll === 'centered' ? '50vh' : ''
  }

  if ('focusMode' in config) {
    document.body.classList.toggle('focus-mode', config.focusMode)
  }

  if ('focusCustom' in config) {
    document.body.classList.toggle('focus-custom', config.focusCustom)
    document.body.classList.toggle('floating', config.focusCustom && !!config.floating)
    if (config.focusCustom) {
      if ('focusDimness' in config)
        document.documentElement.style.setProperty('--focus-dimness', config.focusDimness)
      if ('focusBlur' in config)
        document.documentElement.style.setProperty('--focus-blur', config.focusBlur + 'px')
    }
  }

  if ('imageHalfWidth' in config) {
    let el = document.getElementById('ft-img-style')
    if (!el) {
      el = document.createElement('style')
      el.id = 'ft-img-style'
      document.head.appendChild(el)
    }
    el.textContent = `:root { --ft-img-max-width: ${config.imageHalfWidth ? '50%' : '100%'}; }`
  }

  if ('colors' in config) {
    const r = document.documentElement.style
    for (const [key, val] of Object.entries(config.colors)) {
      if (key === 'selectionBg') {
        // ::selection cannot be set via inline styles; it requires a style rule.
        let sel = document.getElementById('ft-sel')
        if (!sel) {
          sel = document.createElement('style')
          sel.id = 'ft-sel'
          document.head.appendChild(sel)
        }
        sel.textContent = `::selection { background: ${val}; }`
      } else {
        r.setProperty(key, val)
      }
    }
  }
}

// window.editorBridge — called from Swift via evaluateJavaScript

window.editorBridge = {
  /*
    Called once after editorReady, with full document content and initial config.
    Replaces the old sequence of setContent + markClean + setFocusMode +
    applyFocusModeCustomizations + individual style calls.
  */
  load({ content, scrollTop, config }) {
    suppressDocChanged = true
    const effects = buildCompartmentEffects(config || {})
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: content || '' },
      annotations: Transaction.addToHistory.of(false),
      ...(effects.length ? { effects } : {}),
    })
    suppressDocChanged = false
    const ed = document.getElementById('editor')
    if (ed) ed.scrollTop = scrollTop || 0
    applyConfigToDOM(config || {})
  },

  // Called whenever a setting changes. patch contains only the changed keys.
  updateConfig(patch) {
    const effects = buildCompartmentEffects(patch)
    if (effects.length) view.dispatch({ effects })
    applyConfigToDOM(patch)
  },

  toggleSearch() {
    if (searchPanelOpen(view.state)) {
      closeSearchPanel(view)
    } else {
      openSearchPanel(view)
    }
  },

  closeSearch() {
    if (searchPanelOpen(view.state)) closeSearchPanel(view)
  },

  getContent() {
    return view.state.doc.toString()
  },

  setFocusWallpaper(dataURL) {
    document.documentElement.style.setProperty(
      '--focus-wallpaper',
      dataURL ? `url(${dataURL})` : 'none'
    )
  },
}

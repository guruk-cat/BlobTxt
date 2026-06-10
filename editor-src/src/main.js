import { EditorView, keymap, ViewPlugin, Decoration, hoverTooltip } from '@codemirror/view'
import { EditorState, Transaction, Compartment } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { GFM } from '@lezer/markdown'
import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { tags } from '@lezer/highlight'
import {
  search, openSearchPanel, closeSearchPanel, searchPanelOpen, searchKeymap,
  findNext, findPrevious, replaceNext, replaceAll,
  getSearchQuery, setSearchQuery, SearchQuery,
} from '@codemirror/search'

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
    // The search panel matches the body text column width so it stays centered
    // over the text rather than spanning the full editor area.
    '.ft-search': { maxWidth: `${maxWidth}px` },
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

// Base editor theme

/*
  CM6 injects its own base theme via style-mod with 2-class specificity 
  (.generatedClass.cm-button etc.), so external CSS with single-class selectors always loses.
  EditorView.theme() goes through the same system and wins by mount order.

  The fontCompartment below handles font-family, font-size, and heading sizes
  separately because those are reconfigured at runtime when the user changes
  preferences. Everything else is static and belongs here.
*/
const editorBaseTheme = EditorView.theme({
  '&': {
    minHeight: '100%',
    outline: 'none',
    background: 'transparent',
  },
  '&.cm-focused': {
    outline: 'none',
  },
  '.cm-content': {
    color: 'var(--text-body)',
    lineHeight: '2',
    caretColor: 'var(--meta-indication)',
    padding: '0',
    outline: 'none',
  },
  '.cm-scroller': {
    overflow: 'visible',
    margin: '0 auto',
    paddingTop: '48px',
  },
  '.cm-fn-mark':  { color: 'var(--text-muted)' },
  '.cm-fn-label': { color: 'var(--meta-indication)' },
  '.cm-line.cm-md-blockquote': {
    paddingLeft: '2ch',
    textIndent: '-2ch',
  },

  // Footnote hover tooltip. .cm-tooltip is the outer box CM6 positions; the
  // inner .cm-footnote-tooltip holds the definition text. No other tooltips
  // exist in this editor, so styling .cm-tooltip directly is safe.
  '.cm-tooltip': {
    background: 'var(--surface-raised)',
    border: '1px solid var(--surface-sunken)',
    borderRadius: '6px',
    color: 'var(--text-body)',
  },
  '.cm-footnote-tooltip': {
    padding: '8px 12px',
    maxWidth: '320px',
    fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
    fontSize: '14px',
    lineHeight: '1.5',
    whiteSpace: 'normal',
  },

  // Search match highlights. .cm-searchMatch covers every match; the active one
  // gets a stronger fill. Both colors come from palette-derived CSS vars set in
  // applyConfigToDOM (selection color at 0.3, meta-indication at 0.8).
  '.cm-searchMatch': {
    backgroundColor: 'var(--selection-bg)',
    borderRadius: '2px',
  },
  '.cm-searchMatch-selected': {
    backgroundColor: 'var(--match-active-bg)',
  },

  // Strip CM6's default panel chrome so our own card is the only visible surface.
  '.cm-panels': {
    background: 'transparent',
    color: 'inherit',
  },
  '.cm-panels-top': {
    borderBottom: 'none',
  },

  // Custom search panel card. The 8px outer margin and 12px radius mirror the
  // Swift sidebar; max-width is matched to the text column in buildFontTheme so
  // the card tracks body width and centers with it.
  '.ft-search': {
    margin: '8px auto 0',
    padding: '8px',
    background: 'var(--chrome-panel)',
    borderRadius: '12px',
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
    fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
  },
  '.ft-search-row': {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
  },
  // Text fields grow to fill the row; buttons keep their content width and sit
  // to the right of the field (Options/Replace all end up at the right edge).
  '.ft-search-field': {
    flex: '1',
    minWidth: '0',
    background: 'var(--surface)',
    border: '1px solid transparent',
    borderRadius: '8px',
    color: 'var(--text-resting)',
    fontSize: '14px',
    padding: '5px 10px',
    outline: 'none',
    '&::placeholder': { color: 'var(--text-muted)' },
    '&:focus': { borderColor: 'var(--meta-indication)' },
  },
  '.ft-search-btn': {
    flexShrink: '0',
    background: 'var(--surface)',
    border: '1px solid transparent',
    borderRadius: '8px',
    color: 'var(--text-resting)',
    cursor: 'pointer',
    fontSize: '14px',
    padding: '5px 12px',
    whiteSpace: 'nowrap',
    '&:hover': { borderColor: 'var(--meta-indication)' },
    '&:focus': { borderColor: 'var(--meta-indication)', outline: 'none' },
  },
  // Options dropdown: a button plus an absolutely-positioned popover of toggles,
  // anchored to the right edge of the button and overlaying the row below.
  '.ft-search-options': {
    position: 'relative',
    flexShrink: '0',
  },
  '.ft-search-popover': {
    display: 'none',
    position: 'absolute',
    top: 'calc(100% + 4px)',
    right: '0',
    flexDirection: 'column',
    gap: '4px',
    minWidth: '160px',
    padding: '6px',
    background: 'var(--surface)',
    border: '1px solid var(--surface-sunken)',
    borderRadius: '8px',
    zIndex: '20',
    '&.open': { display: 'flex' },
  },
  '.ft-search-option': {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    padding: '4px 6px',
    color: 'var(--text-resting)',
    fontSize: '14px',
    whiteSpace: 'nowrap',
    cursor: 'pointer',
  },
})

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
  { tag: tags.url,       color: 'var(--text-muted)' },
  { tag: tags.labelName, color: 'var(--meta-indication)' },
])

// Line decoration plugin

// Attaches CSS classes to whole lines based on syntax tree node types.
// Token-level styles are handled by HighlightStyle above; line-level layout
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

// Footnote utilities (shared by the hover tooltip and the arrange command)

/*
  A footnote definition is a line "[^label]: text" optionally followed by
  indented continuation lines (GFM syntax). The definition text after "]:" is
  captured in group 2. fnRefRe (defined above) matches inline references.
*/
const fnDefRe = /^\[\^([^\]]+)\]:[ \t]?(.*)$/

/*
  Collects every footnote definition block from an array of document lines.
  Returns the definitions as a Map from label to an array of content lines (the
  text after "]:" plus any de-indented continuation lines), and a Set of every
  line index belonging to a definition block so callers can strip them from the
  body when rewriting the document.
*/
function collectFootnoteDefs(lines) {
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

/*
  Shows the matching definition when the pointer rests on an inline footnote
  reference. The hover source is called with the document position under the
  pointer; we find a [^label] reference spanning that position on its line,
  then look up its definition elsewhere in the document.
*/
const footnoteTooltip = hoverTooltip((view, pos) => {
  const line = view.state.doc.lineAt(pos)
  if (fnDefRe.test(line.text)) return null  // don't trigger on a definition line
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
}, { hideOnChange: true })

// Custom search panel

/*
  Builds the search/replace UI passed to search({ createPanel }). The panel owns
  only its DOM and event wiring; all search behavior is delegated to the exported
  @codemirror/search commands (findNext, replaceAll, …), and the query is driven
  through setSearchQuery. CM6's automatic match highlighting is a function of the
  search state, not the panel, so it keeps working with no extra effort here.

  Layout is two rows:
    Row 1: Find field, Next, Prev, Options (a dropdown of toggles).
    Row 2: Replace field, Replace, Replace all.
*/
function createSearchPanel(view) {
  const dom = document.createElement('div')
  dom.className = 'ft-search'

  // Small helpers for the repeated control types.
  function field(placeholder) {
    const el = document.createElement('input')
    el.className = 'ft-search-field'
    el.placeholder = placeholder
    el.setAttribute('aria-label', placeholder)
    return el
  }
  function button(label, onClick) {
    const b = document.createElement('button')
    b.className = 'ft-search-btn'
    b.type = 'button'
    b.textContent = label
    b.addEventListener('click', e => { e.preventDefault(); onClick() })
    return b
  }

  const findField = field('Find…')
  // CM6 focuses the element marked main-field when the panel opens.
  findField.setAttribute('main-field', 'true')
  const replaceField = field('Replace…')

  const caseToggle = document.createElement('input')
  caseToggle.type = 'checkbox'
  const wordToggle = document.createElement('input')
  wordToggle.type = 'checkbox'

  // Seed every control from any pre-existing query (e.g. reopening the panel).
  const initial = getSearchQuery(view.state)
  findField.value    = initial.search
  replaceField.value = initial.replace
  caseToggle.checked = initial.caseSensitive
  wordToggle.checked = initial.wholeWord

  // Rebuilds the query from current control values and dispatches it, so the
  // highlighted matches and the next find/replace always match what's on screen.
  function commit() {
    view.dispatch({
      effects: setSearchQuery.of(new SearchQuery({
        search:        findField.value,
        replace:       replaceField.value,
        caseSensitive: caseToggle.checked,
        wholeWord:     wordToggle.checked,
      })),
    })
  }
  findField.addEventListener('input', commit)
  replaceField.addEventListener('input', commit)
  caseToggle.addEventListener('change', commit)
  wordToggle.addEventListener('change', commit)

  // Enter / Shift+Enter step through matches; Enter in replace does one replace.
  findField.addEventListener('keydown', e => {
    if (e.key !== 'Enter') return
    e.preventDefault()
    if (e.shiftKey) findPrevious(view)
    else findNext(view)
  })
  replaceField.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); replaceNext(view) }
  })

  // Options dropdown. The popover stays open while toggling and closes on an
  // outside click or a second press of the Options button.
  const optionsWrap = document.createElement('div')
  optionsWrap.className = 'ft-search-options'
  const popover = document.createElement('div')
  popover.className = 'ft-search-popover'
  function optionRow(text, checkbox) {
    const row = document.createElement('label')
    row.className = 'ft-search-option'
    row.appendChild(checkbox)
    row.appendChild(document.createTextNode(text))
    return row
  }
  popover.appendChild(optionRow('Case-sensitive', caseToggle))
  popover.appendChild(optionRow('By word', wordToggle))

  let optionsOpen = false
  function onOutside(e) {
    if (!optionsWrap.contains(e.target)) setOptions(false)
  }
  function setOptions(open) {
    optionsOpen = open
    popover.classList.toggle('open', open)
    if (open) document.addEventListener('mousedown', onOutside)
    else document.removeEventListener('mousedown', onOutside)
  }
  const optionsBtn = button('Options', () => setOptions(!optionsOpen))
  optionsWrap.appendChild(optionsBtn)
  optionsWrap.appendChild(popover)

  const nextBtn = button('Next', () => findNext(view))
  const prevBtn = button('Prev', () => findPrevious(view))
  const row1 = document.createElement('div')
  row1.className = 'ft-search-row'
  row1.appendChild(findField)
  row1.appendChild(nextBtn)
  row1.appendChild(prevBtn)
  row1.appendChild(optionsWrap)

  const replaceBtn    = button('Replace', () => replaceNext(view))
  const replaceAllBtn = button('Replace all', () => replaceAll(view))
  const row2 = document.createElement('div')
  row2.className = 'ft-search-row'
  row2.appendChild(replaceField)
  row2.appendChild(replaceBtn)
  row2.appendChild(replaceAllBtn)

  dom.appendChild(row1)
  dom.appendChild(row2)

  /*
    Sizes the buttons in two independent passes. The top row's three buttons are
    equalized to the widest of them, leaving the find field to flex into the rest
    of the row. The replace field is then pinned to the find field's resulting
    width so the two fields align, and the two bottom buttons are equalized to
    each other at their natural width. The bottom row carries fewer buttons than
    the top, so this intentionally leaves empty space at the bottom-right.
    Buttons use border-box, so style.width maps directly to offsetWidth.
  */
  function balanceRows() {
    const top = [nextBtn, prevBtn, optionsBtn]
    const bottom = [replaceBtn, replaceAllBtn]
    for (const b of [...top, ...bottom]) b.style.width = ''
    replaceField.style.flex = ''
    replaceField.style.width = ''

    // Top row: equalize the three buttons; the find field flexes to fill.
    const a = Math.max(...top.map(b => b.offsetWidth))
    for (const b of top) b.style.width = `${a}px`

    // Bottom row: match the replace field to the now-settled find field width
    // (reading offsetWidth forces the reflow that accounts for the line above).
    replaceField.style.flex = '0 0 auto'
    replaceField.style.width = `${findField.offsetWidth}px`

    // Equalize the two bottom buttons; leftover row space stays empty at right.
    const b = Math.max(...bottom.map(btn => btn.offsetWidth))
    for (const btn of bottom) btn.style.width = `${b}px`
  }

  return {
    dom,
    top: true,
    mount() {
      findField.focus()
      findField.select()
      balanceRows()
    },
    // Keep controls in sync when the query is changed from outside the panel.
    // Skip focused text fields so we never clobber what the user is typing.
    update(u) {
      const q = getSearchQuery(u.state)
      if (document.activeElement !== findField    && q.search  !== findField.value)    findField.value = q.search
      if (document.activeElement !== replaceField && q.replace !== replaceField.value) replaceField.value = q.replace
      caseToggle.checked = q.caseSensitive
      wordToggle.checked = q.wholeWord
    },
    // Ensure the outside-click listener never outlives the panel.
    destroy() { setOptions(false) },
  }
}

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
      footnoteTooltip,
      history(),
      search({ top: true, createPanel: createSearchPanel }),
      keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
      EditorView.lineWrapping,
      editorBaseTheme,
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

// Converts an "rgb(r,g,b)" string into "rgba(r,g,b,a)". Used to derive the
// active search-match background from the meta-indication color.
function rgbToRgba(rgb, alpha) {
  const m = /rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)/.exec(rgb)
  return m ? `rgba(${m[1]}, ${m[2]}, ${m[3]}, ${alpha})` : rgb
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
        // Expose the selection color as a var (reused for all search matches)
        // and inject the ::selection rule, which inline styles cannot set.
        r.setProperty('--selection-bg', val)
        let sel = document.getElementById('ft-sel')
        if (!sel) {
          sel = document.createElement('style')
          sel.id = 'ft-sel'
          document.head.appendChild(sel)
        }
        sel.textContent = `::selection { background: ${val}; }`
      } else {
        r.setProperty(key, val)
        // Derive the active search-match background: meta-indication at 0.8.
        if (key === '--meta-indication') {
          r.setProperty('--match-active-bg', rgbToRgba(val, 0.8))
        }
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

  /*
    Renumbers footnotes and consolidates their definitions, as a single
    transaction. Steps:
      1. Strip all definition blocks out of the document body.
      2. Walk the remaining inline references in order of first appearance and
         assign each distinct label an integer starting at 1.
      3. Rewrite every inline reference with its new number.
      4. Re-append the definitions at the bottom: referenced ones first in the
         new numeric order, then any orphan definitions (defined but never
         referenced) with their labels preserved so nothing is lost.
  */
  arrangeFootnotes() {
    const original = view.state.doc.toString()
    const lines = original.split('\n')
    const { defs, defLineIdx } = collectFootnoteDefs(lines)

    let body = lines.filter((_, i) => !defLineIdx.has(i)).join('\n')

    // Build the rename map from first-appearance order of inline references.
    // Only references that have a matching definition are numbered; references
    // with no definition are orphans and get dropped (see the replace below).
    const order = []
    const seen = new Set()
    fnRefRe.lastIndex = 0
    let m
    while ((m = fnRefRe.exec(body)) !== null) {
      const label = m[1]
      if (!defs.has(label)) continue
      if (!seen.has(label)) { seen.add(label); order.push(label) }
    }
    const rename = new Map()
    order.forEach((label, i) => rename.set(label, String(i + 1)))

    // Renumber defined references; remove orphan references entirely.
    body = body.replace(fnRefRe, (full, label) =>
      rename.has(label) ? `[^${rename.get(label)}]` : '')

    // Reconstruct a definition block with a given label and content lines.
    const renderDef = (label, block) => {
      const first = `[^${label}]: ${block[0]}`.replace(/[ \t]+$/, '')
      const rest = block.slice(1).map(l => '    ' + l)
      return [first, ...rest].join('\n')
    }
    const defBlocks = []
    for (const label of order) {
      if (defs.has(label)) defBlocks.push(renderDef(rename.get(label), defs.get(label)))
    }
    for (const [label, block] of defs) {
      if (!seen.has(label)) defBlocks.push(renderDef(label, block))
    }

    let result = body.replace(/\s+$/, '')
    if (defBlocks.length) result += '\n\n' + defBlocks.join('\n')
    result += '\n'

    if (result === original) return
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: result },
    })
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

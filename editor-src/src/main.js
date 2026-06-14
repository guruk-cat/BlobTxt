import { EditorView, keymap, ViewPlugin, Decoration, hoverTooltip, drawSelection, gutter, GutterMarker } from '@codemirror/view'
import { EditorState, Transaction, Compartment, StateField } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { GFM, parser as baseMarkdownParser } from '@lezer/markdown'
import { HighlightStyle, syntaxHighlighting, syntaxTree, foldGutter, foldKeymap, foldNodeProp } from '@codemirror/language'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { tags, Tag, styleTags } from '@lezer/highlight'
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

// Autoscroll mode does not need a CM compartment — it only gates the JS logic in
// doCenteredScroll.
let autoScrollMode = 'regular'

// Compartments

const fontCompartment = new Compartment()

// Compartment extension builders

function fontFamilyCSS(family) {
  if (family === 'Palatino') return 'Palatino, "Palatino Linotype", serif'
  return 'Menlo, Consolas, "Courier New", monospace'
}

// The runtime-reconfigurable font theme (family, size, heading sizes, text-column width).
function buildFontTheme(fontSize, fontFamily) {
  const size    = fontSize   || 16
  const family  = fontFamilyCSS(fontFamily || 'Menlo')
  const maxWidth = Math.round(820 * size / 18)
  const x = Math.round(size)
  return EditorView.theme({
    '.cm-content': { fontFamily: family, fontSize: `${x}px` },
    '.cm-scroller': { maxWidth: `${maxWidth}px` },
    '.cm-line.cm-md-h1': { fontSize: `${Math.round(x * 1.4)}px`},
    '.cm-line.cm-md-h2': { fontSize: `${Math.round(x * 1.4)}px`},
    '.cm-line.cm-md-h3': { fontSize: `${Math.round(x * 1.4)}px`},
    '.cm-line.cm-md-h4': { fontSize: `${Math.round(x * 1.4)}px`},
    '.cm-line.cm-md-h5': { fontSize: `${Math.round(x * 1.4)}px`},
    // Match the milestone number's line box to one body text row (font size ×
    // the line-height of 2 on .cm-content) so it centers on the first row of
    // its line rather than floating up into the leading above it.
    '.cm-wordcount-gutter .cm-gutterElement': { lineHeight: `${x * 2}px` },
    // The search panel matches the body text column width so it stays centered
    // over the text rather than spanning the full editor area.
    '.ft-search': { maxWidth: `${maxWidth}px` },
  })
}

// Lezer parser extension — footnote exclamation fix (cm-editor-customs.md §4)

/*
  "text![^ref]" makes the GFM Image parser fire on '![' and tag it as a muted
  processingInstruction, even with no trailing '(url)'. Running before the Image
  parser, this consumes the '!' as plain text (returns pos+1, no node) so the
  Image parser never fires and '[^ref]' is parsed normally.
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

// Lezer parser extension — plain bracket fix (cm-editor-customs.md §4)

/*
  A bare "[some text]" is plain prose, but the GFM parser still emits a Link node
  and mutes both brackets. Running before the Link parser, this consumes the '['
  as plain text so no link forms. Genuine syntax is left to the normal parsers
  (returns -1): "[^label]" footnote, "[text](url)" link, "[text][ref]" reference.
*/
const plainBracketFix = {
  parseInline: [{
    name: 'PlainBracketFix',
    before: 'Link',
    parse(cx, next, pos) {
      if (next !== 91) return -1              // not '['
      if (cx.char(pos + 1) === 94) return -1  // '[^' — footnote, leave alone

      // Scan forward for the matching ']' on this line.
      for (let i = pos + 1; i < cx.end; i++) {
        const c = cx.char(i)
        if (c === 10) return -1               // newline before ']' — bail out
        if (c === 91) return -1               // nested '[' — let the Link parser decide
        if (c === 93) {                       // ']'
          const after = cx.char(i + 1)
          if (after === 40 || after === 91) return -1  // '(' or '[' follows → real link/reference
          return pos + 1                      // plain pair — consume '[' as text
        }
      }
      return -1  // no ']' found
    },
  }],
}

// Lezer parser extension — footnote definition fix

/*
  GFM has no footnote-definition block, so a one-word definition "[^label]: word"
  is mistaken for a LinkReference definition (the word is a valid destination) and
  gets HighlightStyle colors that beat our decorations. This replaces the
  LinkReference leaf parser, returning null for "[^...]:" lines so they fall
  through to a normal paragraph; all other lines delegate to the original parser.
*/
const linkReferenceLeaf =
  baseMarkdownParser.leafBlockParsers[baseMarkdownParser.blockNames.indexOf('LinkReference')]

const footnoteDefFix = {
  parseBlock: [{
    name: 'LinkReference',
    leaf(cx, leaf) {
      if (/^\[\^[^\]]+\]:/.test(leaf.content)) return null
      return linkReferenceLeaf ? linkReferenceLeaf(cx, leaf) : null
    },
  }],
}

// Fold configuration — restrict folding to heading sections

/*
  lang-markdown makes every multi-line Block node foldable via foldNodeProp. We
  only want heading sections (which fold via a separate foldService, untouched
  here). This overrides foldNodeProp to yield null for every Block, removing those
  ranges. The null-yielding function is required: returning undefined means "no
  opinion" and leaves lang-markdown's range in place.
*/
const headingOnlyFold = {
  props: [
    foldNodeProp.add(type => type.is('Block') ? () => null : undefined),
  ],
}

// Base editor theme

/*
  All static .cm-* appearance. EditorView.theme() wins over CM6's base theme by
  mount order (see cm-editor-customs.md §3). Runtime-variable styling (font,
  heading sizes, column width) lives in buildFontTheme instead.
*/
const editorBaseTheme = EditorView.theme({
  '&': {
    // A definite height (not just min-height) is required here: .cm-editor is
    // the parent of .cm-scroller, whose base theme height:100% only resolves if
    // this height is definite. min-height alone is treated as indefinite, which
    // collapses the scroller (and the editable .cm-content) to content height,
    // making only the first line clickable on a short/empty blob.
    height: '100%',
    outline: 'none',
    background: 'transparent',
  },
  '&.cm-focused': {
    outline: 'none',
  },
  '.cm-content': {
    color: 'var(--text-body)',
    lineHeight: '2',
    // No caret-color: drawSelection hides the native caret; we style .cm-cursor.
    padding: '0',
    outline: 'none',
  },
  '.cm-scroller': {
    // The real scroll container. #editor is left at overflow:hidden so this
    // element scrolls, which is CM6's native expectation: it makes selection-
    // follow autoscroll and scrollIntoView target the right element. maxWidth
    // (buildFontTheme) + margin auto keep the scrolling column centered.
    overflowY: 'auto',
    width: '100%',
    margin: '0 auto',
    paddingTop: '48px',
    // paddingBottom is not set here: WebKit ignores a scroll container's own
    // bottom padding, so it is applied to .cm-content by the ResizeObserver below.
  },
  '.cm-scroller::-webkit-scrollbar': { display: 'none', width: 0, height: 0 },
  '.cm-fn-mark':  { color: 'var(--text-muted)' },
  '.cm-fn-label': { color: 'var(--meta-indication)' },

  // Cmd+click link affordance.
  // The URL's --text-muted color lives on an inner HighlightStyle span, so the
  // override must also reach descendants (* ) or the child's own color wins.
  '&.cmd-held .cm-blob-link:hover, &.cmd-held .cm-blob-link:hover *': {
    color: 'var(--meta-indication)',
    cursor: 'pointer',
  },
  '.cm-line.cm-md-blockquote': {
    paddingLeft: '2ch',
    textIndent: '-2ch',
  },

  // Caret: CM6's drawn cursor (via drawSelection), styled here for color/height.
  // scaleY frames the glyphs with equal margin above and below; blink rate is set
  // in drawSelection's config.
  '.cm-cursor': {
    borderLeftColor: 'var(--meta-indication)',
    borderLeftWidth: '2px',
    transform: 'scaleY(1.3)',
    transformOrigin: 'center',
  },

  /*
    Selection background, painted by drawSelection. The two rules match the
    specificity of CM6's base &light/&dark unfocused (2 classes) and focused
    (5 classes) rules so mount order wins — those placeholders can't be used in
    EditorView.theme() (cm-editor-customs.md §3.3). --selection-bg is set in
    applyConfigToDOM.
  */
  '.cm-selectionBackground': {
    background: 'var(--selection-bg)',
  },
  '&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground': {
    background: 'var(--selection-bg)',
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

  // Fold gutter. CM6's base theme gives .cm-gutters a grey background and a
  // border-right; both are cleared so the gutter is invisible except for its markers.
  '.cm-gutters': {
    background: 'transparent',
    border: 'none',
  },
  // Word-count milestone gutter: dim, right-aligned numbers with a small gap
  // before the fold gutter / text. tabular-nums keeps widths steady as the
  // numbers grow. The line-height that aligns each number with its text row
  // lives in buildFontTheme, since it tracks the configurable body font size.
  '.cm-wordcount-gutter .cm-gutterElement': {
    color: 'var(--text-muted)',
    fontSize: '12px',
    fontVariantNumeric: 'tabular-nums',
    padding: '0 6px 0 0',
    textAlign: 'right',
    userSelect: 'none',
  },
  '.cm-foldGutter .cm-gutterElement': {
    cursor: 'pointer',
    width: '14px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
  // Open-section indicator: dim at rest, full strength on hover.
  '.ft-fold-open': {
    color: 'var(--text-body)',
    opacity: '0.3',
    fontSize: '16px',
    userSelect: 'none',
    transition: 'opacity 0.15s',
  },
  '.cm-gutterElement:hover .ft-fold-open': {
    opacity: '1',
  },
  // Collapsed-section indicator: always visible so folded content is never hidden silently.
  '.ft-fold-closed': {
    color: 'var(--text-body)',
    opacity: '0.3',
    fontSize: '16px',
    userSelect: 'none',
    transition: 'opacity 0.15s',
  },
  '.cm-gutterElement:hover .ft-fold-closed': {
    opacity: '1',
  },
  // Hide the default [...] inline placeholder CM6 inserts after a folded range.
  '.cm-foldPlaceholder': {
    backgroundColor: 'var(--surface)',
    color: 'var(--text-body)',
    border: 'none',
    padding: '8px',
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
    // position:fixed pins the card to the viewport so it stays put while the
    // document scrolls (a plain CM6 `top` panel has no room to pin in the short
    // .cm-panels-top). left/right:0 + margin auto centers it; maxWidth
    // (buildFontTheme) caps it.
    position: 'fixed',
    top: '8px',
    left: '0',
    right: '0',
    zIndex: '10',
    margin: '0 auto',
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

/*
  The parser tags every mark with the single processingInstruction tag, but two
  groups need different colors: brackets/parens should recede (--text-muted)
  while list bullets, emphasis delimiters, and quote chevrons should stand out
  (--meta-indication). A styleTags override re-tags just the conspicuous node
  types to a custom tag; the rest stay on processingInstruction. (§5.1)
*/
const conspicuousMark = Tag.define()

const conspicuousMarkStyle = {
  props: [
    styleTags({
      'ListMark EmphasisMark QuoteMark': conspicuousMark,
    }),
  ],
}

// Token-level colors and weights. Heading font sizes are NOT set here because
// they scale with the user's font size preference and must change together with
// .cm-content — both are handled by the fontCompartment theme instead.
const highlightStyle = HighlightStyle.define([
  { tag: tags.processingInstruction, color: 'var(--text-muted)' },
  { tag: conspicuousMark, color: 'var(--meta-indication)' },
  { tag: tags.heading1,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.heading2,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.heading3,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.heading4,  color: 'var(--text-heading)', fontWeight: 'bold' },
  { tag: tags.heading5,  color: 'var(--text-heading)', fontWeight: 'bold' },
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

const linkDecorations = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildLinkDecorations(view) }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = buildLinkDecorations(update.view)
    }
  },
  { decorations: v => v.decorations }
)

// Word-count milestone gutter

// Places a gutter number on each line where the running word count first crosses
// a multiple of 100, so the margin reads 100, 200, 300… down the document. A
// "word" is a run of letters/digits (with internal apostrophes or hyphens), so
// bare markdown punctuation (#, -, *, >) is not counted. Code blocks and the
// like are counted as plain text; there is no syntax-level special-casing.
const wordRe = /[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/gu

// Indexed by 1-based line number: the milestone to show on that line, or 0 for
// none. If a line crosses more than one hundred at once (a long wrapped
// paragraph), the highest one reached is shown, since only one marker fits.
function computeWordMilestones(doc) {
  const milestones = new Array(doc.lines + 1)
  let total = 0
  for (let i = 1; i <= doc.lines; i++) {
    const prev = total
    const matches = doc.line(i).text.match(wordRe)
    if (matches) total += matches.length
    const highest = Math.floor(total / 100) * 100
    milestones[i] = highest > prev ? highest : 0
  }
  return milestones
}

const wordMilestones = StateField.define({
  create(state) { return computeWordMilestones(state.doc) },
  update(value, tr) {
    return tr.docChanged ? computeWordMilestones(tr.state.doc) : value
  },
})

class MilestoneMarker extends GutterMarker {
  constructor(number) { super(); this.number = number }
  eq(other) { return this.number === other.number }
  toDOM() { return document.createTextNode(String(this.number)) }
}

const wordCountGutter = gutter({
  class: 'cm-wordcount-gutter',
  lineMarker(view, line) {
    const n = view.state.field(wordMilestones)[view.state.doc.lineAt(line.from).number]
    return n ? new MilestoneMarker(n) : null
  },
  lineMarkerChange(update) { return update.docChanged },
})

// Cmd-held tracking plugin

// Reads metaKey primarily from mousemove because macOS keyup for the Cmd key is
// unreliable; keydown/keyup and window blur are backups.
const cmdKeyTracking = ViewPlugin.fromClass(
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

// Link navigation

/*
  Maps a heading's text to its anchor slug, GitHub-style: lowercase, punctuation
  dropped, runs of whitespace collapsed to single hyphens. This is the single
  definition shared by in-document anchor links and (later) link autocomplete.
*/
function slugify(text) {
  return text.trim().toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .replace(/\s+/g, '-')
}

// Finds the line-start position of the first heading whose slug matches, or null.
function headingPosForSlug(view, slug) {
  const target = slug.toLowerCase()
  const doc = view.state.doc
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i)
    const m = /^#{1,6}\s+(.*)$/.exec(line.text)
    if (m && slugify(m[1]) === target) return line.from
  }
  return null
}

// Moves the caret to the matching heading and scrolls it near the top.
function goToHeading(view, fragment) {
  let slug = fragment
  try { slug = decodeURIComponent(fragment) } catch (e) {}
  const pos = headingPosForSlug(view, slug)
  if (pos === null) return
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 48 }),
  })
}

/*
  Classifies a Cmd+clicked link target and routes it. A scheme (http:, mailto:,
  …), a www. autolink, or an email goes to the system handler via Swift. A bare
  "#fragment" scrolls within this blob. Anything else is a local path that Swift
  resolves against the current file and opens, with any "#fragment" split off so
  the opened blob can scroll to it.
*/
function openLink(href, view) {
  const hasScheme = /^[a-z][a-z0-9+.-]*:/i.test(href)
  const isWww     = /^www\./i.test(href)
  if (hasScheme || isWww) { post({ type: 'openURL', url: href }); return }
  if (!hasScheme && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(href)) {
    post({ type: 'openURL', url: 'mailto:' + href }); return
  }
  if (href.startsWith('#')) { goToHeading(view, href.slice(1)); return }
  const hashIdx  = href.indexOf('#')
  const path     = hashIdx === -1 ? href : href.slice(0, hashIdx)
  const fragment = hashIdx === -1 ? ''   : href.slice(hashIdx + 1)
  post({ type: 'openBlob', path, fragment })
}

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

const footnoteHover = hoverTooltip(footnoteTipAt, { hideOnChange: true })

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
    Two passes. Top row: equalize the three buttons to the widest, find field
    flexes to fill. Bottom row: pin the replace field to the find field's settled
    width so the two fields align, then equalize the two bottom buttons (leaving
    empty space at bottom-right). Buttons are border-box, so style.width == offsetWidth.
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
// scroll container. Only active when autoScrollMode is 'centered'.
function doCenteredScroll() {
  if (autoScrollMode !== 'centered') return
  const coords = view.coordsAtPos(view.state.selection.main.head)
  if (!coords) return
  const ed        = view.scrollDOM
  const edRect    = ed.getBoundingClientRect()
  const cursorY   = (coords.top + coords.bottom) / 2
  const edCenterY = edRect.top + ed.clientHeight / 2
  if (cursorY <= edCenterY) return
  ed.scrollTo({ top: Math.max(0, ed.scrollTop + (cursorY - edCenterY)), behavior: 'smooth' })
}

// Editor initialization

const view = new EditorView({
  state: EditorState.create({
    doc: '',
    extensions: [
      markdown({ extensions: [footnoteImageFix, plainBracketFix, GFM, footnoteDefFix, conspicuousMarkStyle, headingOnlyFold] }),
      syntaxHighlighting(highlightStyle),
      headingLineDecorations,
      inlineMarkDecorations,
      linkDecorations,
      cmdKeyTracking,
      footnoteHover,
      history(),
      // Word-count milestone gutter (leftmost, before the fold gutter). The
      // state field holds the precomputed per-line milestone the gutter reads.
      wordMilestones,
      wordCountGutter,
      foldGutter({
        markerDOM(open) {
          const span = document.createElement('span')
          span.className = open ? 'ft-fold-open' : 'ft-fold-closed'
          span.textContent = open ? '▾' : '›'
          return span
        },
      }),
      // Draws CM6's own caret and selection rects (replacing the native ones)
      // so the caret can be themed and its blink controlled. cursorBlinkRate is
      // in ms; the default 1200 gives a calm hard blink.
      drawSelection({ cursorBlinkRate: 1200 }),
      search({ top: true, createPanel: createSearchPanel }),
      keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, ...foldKeymap]),
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
        // and route it (see openLink). CodeMirror renders links as styled spans
        // (no <a> elements), so we can't rely on event.target.closest('a').
        click(event, v) {
          if (!event.metaKey) return false
          const pos = v.posAtCoords({ x: event.clientX, y: event.clientY })
          if (pos === null) return false
          let node = syntaxTree(v.state).resolve(pos, 1)
          while (node) {
            if (node.name === 'URL') {
              let href = v.state.doc.sliceString(node.from, node.to)
              if (href.startsWith('<') && href.endsWith('>')) href = href.slice(1, -1)
              openLink(href, v)
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

// Keeps .cm-content's bottom padding at half the scroll container's height so the
// last lines can scroll up to the vertical middle. It must live on .cm-content,
// not the scroller: WebKit ignores a scroll container's own bottom padding.
// Inline + ResizeObserver because the value tracks the live height.
const bottomPadObserver = new ResizeObserver(entries => {
  const sc = entries[0].target
  view.contentDOM.style.paddingBottom = `${Math.round(sc.clientHeight / 2)}px`
})
bottomPadObserver.observe(view.scrollDOM)

// Scroll position tracking → Swift

let scrollTimer = null
view.scrollDOM.addEventListener('scroll', () => {
  clearTimeout(scrollTimer)
  scrollTimer = setTimeout(() => {
    post({ type: 'scrollPositionChanged', scrollTop: Math.round(view.scrollDOM.scrollTop) })
  }, 300)
})

// Config application helpers

// Reconfigure effects for any compartment whose key appears in the patch. The
// font theme needs both size and family, so both are mirrored here for partial patches.
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
  autoscroll mode, CSS variables, and the ::selection color injected via a style
  element.
*/
function applyConfigToDOM(config) {
  if ('autoscroll' in config) {
    // Only toggles cursor re-centering (doCenteredScroll); the bottom padding
    // that gives the last lines room is kept in every mode by the ResizeObserver.
    autoScrollMode = config.autoscroll
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
  // Called once after editorReady, with full document content and initial config.
  load({ content, scrollTop, config }) {
    suppressDocChanged = true
    const effects = buildCompartmentEffects(config || {})
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: content || '' },
      annotations: Transaction.addToHistory.of(false),
      ...(effects.length ? { effects } : {}),
    })
    suppressDocChanged = false
    view.scrollDOM.scrollTop = scrollTop || 0
    applyConfigToDOM(config || {})

    // Empty blob: focus and place the caret so the user can type immediately.
    // A non-empty blob opens unfocused so reading it never risks stray edits.
    if (!content || content.trim().length === 0) {
      view.focus()
      view.dispatch({ selection: { anchor: 0 } })
    }
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

  // Called by Swift after opening a blob via a cross-file anchor link, to scroll
  // the freshly loaded document to the linked heading.
  scrollToHeading(fragment) {
    if (fragment) goToHeading(view, fragment)
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
}

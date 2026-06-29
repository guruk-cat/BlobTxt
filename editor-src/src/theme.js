import { EditorView } from '@codemirror/view'

function fontFamilyCSS(family) {
  if (family === 'Palatino') return 'Palatino, "Palatino Linotype", serif'
  return 'Menlo, Consolas, "Courier New", monospace'
}

// The runtime-reconfigurable font theme (family, size, heading sizes, text-column width).
export function buildFontTheme(fontSize, fontFamily) {
  const size    = fontSize   || 16
  const family  = fontFamilyCSS(fontFamily || 'Menlo')
  const maxWidth = Math.round(820 * size / 18)
  const x = Math.round(size)
  // Space kept on each side of the column so the out-of-flow gutters have room in
  // the left margin even when the window is narrower than the column.
  const gutterReserve = 56
  // The actual column width: the calculated maximum, but shrinking to leave the
  // reserve on each side once the window can no longer fit the full column. The
  // gutter anchor below reuses this so it tracks the column's real left edge
  // rather than the maximum.
  const colWidth = `min(${maxWidth}px, 100% - ${gutterReserve * 2}px)`
  return EditorView.theme({
    // The centered text column. The scroller spans the full editor width; this
    // column carries the width and auto side margins, so the text stays centered
    // regardless of gutter width (cm-editor-customs.md §1.3). CM6's base gives
    // .cm-content flex-grow:2, which would fill the scroller; flexGrow:0 cancels
    // that so the explicit width defines the column.
    '.cm-content': {
      fontFamily: family,
      fontSize: `${x}px`,
      width: colWidth,
      margin: '0 auto',
      flexGrow: 0,
      flexShrink: 1,
    },
    // The gutter is taken out of flow and pinned by its right edge at the text
    // column's left edge: half the editor in, then half the column back out.
    // left:auto clears CM6's base .cm-gutters-before { inset-inline-start: 0 };
    // without it, left:0 + right together would stretch the box instead.
    '.cm-gutters': {
      left: 'auto',
      right: `calc(50% + ${colWidth} / 2)`,
    },
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

/*
  All static .cm-* appearance. EditorView.theme() wins over CM6's base theme by
  mount order (see cm-editor-customs.md §3). Runtime-variable styling (font,
  heading sizes, column width) lives in buildFontTheme instead.
*/
export const editorBaseTheme = EditorView.theme({
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
    // follow autoscroll and scrollIntoView target the right element. It spans
    // the full editor width; the centered text column is .cm-content
    // (buildFontTheme), which leaves a margin for the out-of-flow gutter.
    overflowY: 'auto',
    width: '100%',
    paddingTop: '48px',
    // paddingBottom is not set here: WebKit ignores a scroll container's own
    // bottom padding, so it is applied to .cm-content by the ResizeObserver below.
  },
  '.cm-scroller::-webkit-scrollbar': { display: 'none', width: 0, height: 0 },
  '.cm-fn-mark':  { color: 'var(--text-muted)' },
  '.cm-fn-label': { color: 'var(--meta-indication)' },

  // Math: '$'/'$$' delimiters recede to meta-indication; the expression takes
  // body color. The descendant override (* ) wins over any inner HighlightStyle
  // span and strips stray markdown emphasis inside the math (e.g. $*x*$).
  '.cm-math-mark': { color: 'var(--meta-indication)' },
  '.cm-math-expr, .cm-math-expr *': {
    color: 'var(--text-body)',
    fontStyle: 'normal',
    fontWeight: 'normal',
  },

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
    background: 'var(--surface-sunken)',
    border: '1px solid var(--border)',
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
  // KaTeX-rendered math tooltip. KaTeX brings its own fonts/sizing via
  // katex.min.css; this just gives the box padding and a sensible base size.
  '.cm-math-tooltip': {
    padding: '8px 14px',
    fontSize: '15px',
    color: 'var(--text-body)',
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

  // The gutter container. CM6's base theme gives it a grey background and a
  // border-right; both are cleared so the gutter is invisible except for its
  // markers. position:absolute takes it out of the scroller's flex row so it no
  // longer pushes the text column; it hangs in the left margin instead, pinned
  // by the `right` value in buildFontTheme. The gutters({ fixed: false })
  // extension is what frees this: it stops CM6 from forcing inline position:sticky.
  '.cm-gutters': {
    background: 'transparent',
    border: 'none',
    position: 'absolute',
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

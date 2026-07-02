import { EditorView, keymap, drawSelection, gutters } from '@codemirror/view'
import { EditorState, Transaction, Compartment } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { GFM } from '@lezer/markdown'
import { syntaxHighlighting, syntaxTree, foldGutter, foldKeymap, foldEffect, foldedRanges, foldable } from '@codemirror/language'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import {
  search, openSearchPanel, closeSearchPanel, searchPanelOpen, searchKeymap,
} from '@codemirror/search'

import { post, state } from './state.js'
import { editorBaseTheme, buildFontTheme } from './theme.js'
import { highlightStyle, conspicuousMarkStyle } from './highlight.js'
import { footnoteImageFix, plainBracketFix, footnoteDefFix, frontmatter, headingOnlyFold } from './parser-extensions.js'
import { headingLineDecorations, inlineMarkDecorations, linkDecorations, cmdKeyTracking } from './decorations.js'
import { wordMilestones, wordCountGutter } from './gutters.js'
import { footnoteHover, collectFootnoteDefs, fnRefRe } from './footnotes.js'
import { mathDecorations, mathHover } from './math.js'
import { citeDecorations } from './citations.js'
import { goToHeading, openLink, slugify, headingPosForSlug } from './links.js'
import { createSearchPanel } from './search-panel.js'
import 'katex/dist/katex.min.css'

// Compartments

const fontCompartment = new Compartment()

// Centered scroll

// Keeps the cursor vertically centered when it moves past the midpoint of the
// scroll container. Only active when state.autoScrollMode is 'centered'.
function doCenteredScroll() {
  if (state.autoScrollMode !== 'centered') return
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
      markdown({ extensions: [footnoteImageFix, plainBracketFix, GFM, footnoteDefFix, frontmatter, conspicuousMarkStyle, headingOnlyFold] }),
      syntaxHighlighting(highlightStyle),
      headingLineDecorations,
      inlineMarkDecorations,
      linkDecorations,
      cmdKeyTracking,
      mathDecorations,
      citeDecorations,
      footnoteHover,
      mathHover,
      history(),
      // Unfix the gutters so they can be positioned by CSS (out of flow, in the
      // left margin); see the .cm-gutters theme rule. Without this CM6 pins them
      // with an inline position:sticky that no stylesheet can override.
      gutters({ fixed: false }),
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
        if (update.docChanged && !state.suppressDocChanged) {
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

// Folds are keyed by heading slug. Two identical headings share a slug, so
// restore folds the first match (acceptable until it isn't).

// Slugs of every currently folded heading, in document order.
function currentFoldSlugs() {
  const doc = view.state.doc
  const slugs = []
  foldedRanges(view.state).between(0, doc.length, from => {
    const m = /^#{1,6}\s+(.*)$/.exec(doc.lineAt(from).text)
    if (m) slugs.push(slugify(m[1]))
  })
  return slugs
}

// Re-folds the headings named by `slugs`. Runs after the document is in place;
// headings whose slug no longer resolves (renamed/deleted) are skipped.
function applyFolds(slugs) {
  const effects = []
  for (const slug of slugs) {
    const pos = headingPosForSlug(view, slug)
    if (pos === null) continue
    const line  = view.state.doc.lineAt(pos)
    const range = foldable(view.state, line.from, line.to)
    if (range) effects.push(foldEffect.of(range))
  }
  if (effects.length) view.dispatch({ effects })
}

// Config application helpers

// Reconfigure effects for any compartment whose key appears in the patch. The
// font theme needs both size and family, so both are mirrored in state for partial patches.
function buildCompartmentEffects(config) {
  const effects = []
  if ('fontSize' in config || 'fontFamily' in config) {
    if ('fontSize'   in config) state.fontSize   = config.fontSize
    if ('fontFamily' in config) state.fontFamily = config.fontFamily
    effects.push(fontCompartment.reconfigure(buildFontTheme(state.fontSize, state.fontFamily)))
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
    state.autoScrollMode = config.autoscroll
  }

  if ('mini' in config) {
    // Mini view styling: reduced page padding (skeleton rule on #editor).
    document.getElementById('editor').classList.toggle('mini', !!config.mini)
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
  load({ content, scrollTop, config, folds }) {
    state.suppressDocChanged = true
    const effects = buildCompartmentEffects(config || {})
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: content || '' },
      annotations: Transaction.addToHistory.of(false),
      ...(effects.length ? { effects } : {}),
    })
    state.suppressDocChanged = false
    view.scrollDOM.scrollTop = scrollTop || 0
    applyConfigToDOM(config || {})

    // Restore folds after the doc is set; rAF lets the parser settle so foldable()
    // can resolve heading ranges. The resulting foldEffects round-trip back to
    // Swift via the updateListener, repopulating the cached fold list.
    if (folds && folds.length) requestAnimationFrame(() => applyFolds(folds))

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
    A reference with no matching definition is not dropped: its own bracket text
    becomes the definition content (so "[^Oh, yes!]" becomes "[^1]" plus a
    "[^1]: Oh, yes!" definition).
  */
  arrangeFootnotes() {
    const original = view.state.doc.toString()
    const lines = original.split('\n')
    const { defs, defLineIdx } = collectFootnoteDefs(lines)

    // Removing a definition line between two blank lines would leave a double
    // blank behind, so collapse any run of blank lines the strip opened up.
    let body = lines.filter((_, i) => !defLineIdx.has(i)).join('\n').replace(/\n{3,}/g, '\n\n')

    // Build the rename map from first-appearance order of inline references.
    // Every referenced label is numbered, whether or not it has a definition;
    // an undefined label keeps its text to use as the synthesized definition.
    const order = []
    const seen = new Set()
    fnRefRe.lastIndex = 0
    let m
    while ((m = fnRefRe.exec(body)) !== null) {
      const label = m[1]
      if (!seen.has(label)) { seen.add(label); order.push(label) }
    }
    const rename = new Map()
    order.forEach((label, i) => rename.set(label, String(i + 1)))

    // Renumber every reference.
    body = body.replace(fnRefRe, (full, label) => `[^${rename.get(label)}]`)

    // Reconstruct a definition block with a given label and content lines.
    const renderDef = (label, block) => {
      const first = `[^${label}]: ${block[0]}`.replace(/[ \t]+$/, '')
      const rest = block.slice(1).map(l => '    ' + l)
      return [first, ...rest].join('\n')
    }
    const defBlocks = []
    for (const label of order) {
      const block = defs.has(label) ? defs.get(label) : [label]
      defBlocks.push(renderDef(rename.get(label), block))
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

  // This surface's session view state (folded headings by slug, plus scroll position), pulled by Swift on the save/flush path before teardown.
  getViewState() {
    return {
      folds: currentFoldSlugs(),
      scrollTop: Math.round(view.scrollDOM.scrollTop),
    }
  },
}

import {
  Editor,
  rootCtx,
  parserCtx,
  editorViewCtx,
  remarkPluginsCtx,
} from '@milkdown/core'
import {
  commonmark,
  toggleStrongCommand,
  toggleEmphasisCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand,
  wrapInHeadingCommand,
  updateLinkCommand,
  insertImageCommand,
} from '@milkdown/preset-commonmark'
import { listener, listenerCtx } from '@milkdown/plugin-listener'
import { history } from '@milkdown/plugin-history'
import { callCommand, getMarkdown, $node, $prose } from '@milkdown/utils'
import { Plugin, PluginKey, TextSelection } from '@milkdown/prose/state'
import { toggleMark } from '@milkdown/prose/commands'
import { DecorationSet, Decoration } from '@milkdown/prose/view'
import { Slice } from '@milkdown/prose/model'
import remarkGfm from 'remark-gfm'

// ── Swift bridge ──────────────────────────────────────────────────────────────

function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

// ── Footnote renumbering ──────────────────────────────────────────────────────
//
// Applied to the Markdown string returned by getContent(). Rewrites all
// footnote reference IDs to clean sequential integers (1, 2, 3, …) in
// document order, regardless of how editing has shuffled them.

function renumberMarkdown(markdown) {
  const map = new Map() // oldId → newSequentialId (string)
  let counter = 0

  // First pass: discover IDs in order of first reference appearance.
  markdown.replace(/\[\^([^\]]+)\]/g, (_, id) => {
    if (!map.has(id)) {
      counter++
      map.set(id, String(counter))
    }
  })

  if (map.size === 0) return markdown

  // Second pass: rewrite both inline references [^id] and definitions [^id]:.
  return markdown.replace(/\[\^([^\]]+)\](:)?/g, (match, id, colon) => {
    const newId = map.get(id)
    if (!newId) return match
    return colon ? `[^${newId}]:` : `[^${newId}]`
  })
}

// ── Search highlight ProseMirror plugin ──────────────────────────────────────
//
// Tracks search result ranges and renders them as inline decorations.
// Controlled via transaction meta — set by editorBridge.searchAndHighlight,
// cleared by editorBridge.clearSearchHighlights.

const searchKey = new PluginKey('searchHighlight')
let searchRanges = []

const searchHighlightPlugin = $prose(() => new Plugin({
  key: searchKey,
  state: {
    init: () => DecorationSet.empty,
    apply(tr, set) {
      const meta = tr.getMeta(searchKey)
      if (meta === 'clear') return DecorationSet.empty
      if (Array.isArray(meta)) {
        const decos = meta.map(({ from, to }) =>
          Decoration.inline(from, to, { class: 'search-highlight' })
        )
        return DecorationSet.create(tr.doc, decos)
      }
      return set.map(tr.mapping, tr.doc)
    },
  },
  props: {
    decorations(state) { return searchKey.getState(state) },
  },
}))

// ── User interaction tracking ProseMirror plugin ──────────────────────────────
//
// Tracks whether the user has clicked to place the cursor. Gates the custom
// cursor display and blocks keystrokes before the first deliberate click.

const userInteractKey = new PluginKey('userInteract')

const userInteractPlugin = $prose(() => new Plugin({
  key: userInteractKey,
  state: {
    init: () => false,
    apply(tr, prev) {
      const meta = tr.getMeta(userInteractKey)
      if (meta === true || meta === false) return meta
      if (tr.getMeta('pointer') && !prev) return true
      return prev
    },
  },
  props: {
    // Block all keystrokes until the user has clicked to place the cursor.
    handleKeyDown(view) {
      return !userInteractKey.getState(view.state)
    },
    // Two cases arise on click:
    //   (a) Pointer transaction fired during mousedown → userInteracted is already true.
    //   (b) Click did not change the selection (e.g. clicking in an empty paragraph
    //       already at position 1) → pointer transaction skipped → still false.
    // Case (b) is handled here by dispatching our own transaction.
    handleClick(view) {
      if (!userInteractKey.getState(view.state)) {
        view.dispatch(view.state.tr.setMeta(userInteractKey, true))
      }
      updateCursor()
      return false
    },
  },
}))

// ── Footnote paste ProseMirror plugin ─────────────────────────────────────────
//
// Intercepts clipboard text before Milkdown parses it. When the pasted text
// contains footnote markers that conflict with IDs already in the document,
// the pasted IDs are renumbered to avoid collisions. Returning the modified
// string lets Milkdown's default paste handler insert the content normally.

function getMaxFootnoteLabel(doc) {
  let max = 0
  doc.descendants(node => {
    if (node.type.name === 'footnoteReference') {
      const n = parseInt(node.attrs.label, 10)
      if (!isNaN(n) && n > max) max = n
    }
  })
  return max
}

function renumberPastedFootnotes(text, offset) {
  const idMap = new Map()
  let counter = 0

  text.replace(/\[\^([^\]]+)\]/g, (_, id) => {
    if (!idMap.has(id)) {
      counter++
      idMap.set(id, String(offset + counter))
    }
  })

  if (idMap.size === 0) return text

  return text.replace(/\[\^([^\]]+)\](:)?/g, (match, id, colon) => {
    const newId = idMap.get(id)
    if (!newId) return match
    return colon ? `[^${newId}]:` : `[^${newId}]`
  })
}

const footnotePastePlugin = $prose(() => new Plugin({
  key: new PluginKey('footnotePaste'),
  props: {
    // transformPastedText runs before Milkdown parses the clipboard, so
    // returning a modified string is all that's needed.
    transformPastedText(text) {
      if (!text.includes('[^')) return text
      if (!editor) return text
      const view = editor.action(ctx => ctx.get(editorViewCtx))
      const maxLabel = getMaxFootnoteLabel(view.state.doc)
      if (maxLabel === 0) return text  // No existing footnotes → no conflict.
      return renumberPastedFootnotes(text, maxLabel)
    },
  },
}))

// ── Footnote schema nodes ─────────────────────────────────────────────────────
//
// Milkdown has no first-party footnote plugin. These two $node plugins define:
//   • ProseMirror schema spec (group, content, attrs, toDOM, parseDOM)
//   • Parser rules  — remark-gfm AST → ProseMirror node
//   • Serializer rules — ProseMirror node → remark-gfm AST
//
// footnoteReference  inline atom  rendered as <sup class="footnote-ref">[^N]</sup>
// footnoteDefinition block node   rendered as <div class="footnote-def">…</div>
//
// remark-gfm (added to the remark pipeline in Editor.make().config) handles
// Markdown ↔ AST conversion. These plugins bridge between the remark-gfm
// AST node types ('footnoteReference', 'footnoteDefinition') and ProseMirror.

const footnoteReferencePlugin = $node('footnoteReference', () => ({
  group: 'inline',
  inline: true,
  atom: true,
  attrs: { label: { default: '1' } },
  toDOM(node) {
    return ['sup', {
      class: 'footnote-ref',
      'data-footnote': node.attrs.label,
      'data-type': 'footnoteReference',
    }, `[^${node.attrs.label}]`]
  },
  parseDOM: [{
    tag: 'sup[data-footnote]',
    getAttrs(dom) { return { label: dom.getAttribute('data-footnote') } },
  }],
  parseMarkdown: {
    match: (node) => node.type === 'footnoteReference',
    runner: (state, node, type) => {
      state.addNode(type, { label: node.identifier })
    },
  },
  toMarkdown: {
    match: (node) => node.type.name === 'footnoteReference',
    runner: (state, node) => {
      state.addNode('footnoteReference', undefined, undefined, {
        identifier: node.attrs.label,
        label: node.attrs.label,
      })
    },
  },
}))

const footnoteDefinitionPlugin = $node('footnoteDefinition', () => ({
  group: 'block',
  content: 'block+',
  attrs: { label: { default: '1' } },
  toDOM(node) {
    return ['div', {
      class: 'footnote-def',
      'data-footnote-id': node.attrs.label,
      'data-type': 'footnoteDefinition',
    }, 0]
  },
  parseDOM: [{
    tag: 'div[data-footnote-id]',
    getAttrs(dom) { return { label: dom.getAttribute('data-footnote-id') } },
  }],
  parseMarkdown: {
    match: (node) => node.type === 'footnoteDefinition',
    runner: (state, node, type) => {
      state.openNode(type, { label: node.identifier })
      state.next(node.children)
      state.closeNode()
    },
  },
  toMarkdown: {
    match: (node) => node.type.name === 'footnoteDefinition',
    runner: (state, node) => {
      state.openNode('footnoteDefinition', undefined, {
        identifier: node.attrs.label,
        label: node.attrs.label,
      })
      state.next(node.content)
      state.closeNode()
    },
  },
}))

// ── State query helpers ───────────────────────────────────────────────────────
//
// Replacements for TipTap's editor.isActive(). Called with a ProseMirror
// state obtained via editor.action(ctx => ctx.get(editorViewCtx).state).

function isMarkActive(state, markName) {
  const { from, to, empty } = state.selection
  const markType = state.schema.marks[markName]
  if (!markType) return false
  if (empty) {
    return !!(state.storedMarks || state.selection.$from.marks()).find(
      m => m.type === markType
    )
  }
  return state.doc.rangeHasMark(from, to, markType)
}

function isBlockTypeActive(state, typeName, attrKey, attrVal) {
  const { $from, to } = state.selection
  const nodeType = state.schema.nodes[typeName]
  if (!nodeType) return false
  let found = false
  state.doc.nodesBetween($from.pos, to, node => {
    if (found) return false
    if (node.type === nodeType) {
      if (attrKey === undefined || node.attrs[attrKey] === attrVal) {
        found = true
        return false
      }
    }
  })
  return found
}

function getActiveHeadingLevel(state) {
  const { $from, to } = state.selection
  const nodeType = state.schema.nodes.heading
  if (!nodeType) return 0
  let level = 0
  state.doc.nodesBetween($from.pos, to, node => {
    if (level) return false
    if (node.type === nodeType) { level = node.attrs.level; return false }
  })
  return level
}

// ── Module-level state ────────────────────────────────────────────────────────

let editor = null
let autoScrollMode = 'regular'

// Custom cursor element — appended to #editor after the editor is created.
const cur = document.createElement('div')
cur.id = 'custom-cursor'

// ── Cursor, scroll, and state update (called from listener and event handlers)

function sendStateUpdate() {
  if (!editor) return
  const state = editor.action(ctx => ctx.get(editorViewCtx).state)
  post({
    type: 'stateUpdate',
    bold:        isMarkActive(state, 'strong'),
    italic:      isMarkActive(state, 'emphasis'),
    heading:     getActiveHeadingLevel(state),
    bulletList:  isBlockTypeActive(state, 'bullet_list'),
    orderedList: isBlockTypeActive(state, 'ordered_list'),
    blockquote:  isBlockTypeActive(state, 'blockquote'),
    linkActive:  isMarkActive(state, 'link'),
  })
}

function updateCursor() {
  if (!editor) { cur.style.display = 'none'; return }
  const view = editor.action(ctx => ctx.get(editorViewCtx))
  if (!view.hasFocus() || !view.state.selection.empty) {
    cur.style.display = 'none'
    return
  }
  if (!userInteractKey.getState(view.state)) {
    cur.style.display = 'none'
    return
  }
  const pos = view.state.selection.$head.pos
  try {
    const coords   = view.coordsAtPos(pos)
    const domPos   = view.domAtPos(pos)
    let node       = domPos.node
    if (node.nodeType === 3) node = node.parentElement
    const style    = getComputedStyle(node)
    const fontSize = parseFloat(style.fontSize) || 22
    const cursorH  = fontSize * 1.5
    const charH    = coords.bottom - coords.top
    const ed       = document.getElementById('editor')
    const edRect   = ed.getBoundingClientRect()
    const textCenter = coords.top + (charH / 2) - edRect.top + ed.scrollTop
    cur.style.top    = (textCenter - cursorH / 2) + 'px'
    cur.style.left   = (coords.left - edRect.left) + 'px'
    cur.style.height = cursorH + 'px'
    cur.style.display = 'block'
    cur.classList.remove('blinking')
    void cur.offsetWidth  // force reflow to restart the blink animation
    cur.classList.add('blinking')
  } catch {
    cur.style.display = 'none'
  }
}

function doCenteredScroll() {
  if (autoScrollMode !== 'centered') return
  const sel = window.getSelection()
  if (!sel || sel.rangeCount === 0) return
  const range = sel.getRangeAt(0)
  const rect  = range.getBoundingClientRect()
  if (rect.height === 0) return
  const ed        = document.getElementById('editor')
  const edRect    = ed.getBoundingClientRect()
  const cursorCenterY = rect.top + rect.height / 2
  const edCenterY     = edRect.top + ed.clientHeight / 2
  if (cursorCenterY <= edCenterY) return
  const targetScroll = ed.scrollTop + (cursorCenterY - edCenterY)
  ed.scrollTo({ top: Math.max(0, targetScroll), behavior: 'smooth' })
}

// ── Editor creation ───────────────────────────────────────────────────────────

;(async () => {
  editor = await Editor.make()
    .config(ctx => {
      ctx.set(rootCtx, document.getElementById('editor'))

      // Add remark-gfm to the remark pipeline for footnote parsing.
      ctx.update(remarkPluginsCtx, plugins => [
        ...plugins,
        { plugin: remarkGfm, options: {} },
      ])

      // updated fires (debounced ~200ms) only when the document content changes.
      // selectionUpdated fires immediately on any selection move.
      ctx.get(listenerCtx)
        .updated(() => {
          post({ type: 'documentChanged' })
          sendStateUpdate()
          requestAnimationFrame(doCenteredScroll)
          updateCursor()
        })
        .selectionUpdated(() => {
          sendStateUpdate()
          updateCursor()
        })
    })
    .use(commonmark)
    .use(listener)
    .use(history)
    .use(searchHighlightPlugin)
    .use(userInteractPlugin)
    .use(footnotePastePlugin)
    .use(footnoteReferencePlugin)
    .use(footnoteDefinitionPlugin)
    .create()

  post({ type: 'editorReady' })

  // Append custom cursor div inside the editor container.
  document.getElementById('editor').appendChild(cur)

  const view = editor.action(ctx => ctx.get(editorViewCtx))

  // Focus and blur update the custom cursor.
  view.dom.addEventListener('focus', updateCursor, true)
  view.dom.addEventListener('blur',  updateCursor, true)

  // ⌘+click opens a hyperlink in the system browser.
  view.dom.addEventListener('click', e => {
    if (!e.metaKey) return
    const a = e.target.closest('a[href]')
    if (!a) return
    e.preventDefault()
    post({ type: 'openURL', url: a.href })
  })

  // ⌘K opens the hyperlink dialog.
  view.dom.addEventListener('keydown', e => {
    if (e.key === 'k' && e.metaKey) {
      e.preventDefault()
      const state = editor.action(ctx => ctx.get(editorViewCtx).state)
      const mark = state.schema.marks.link
      const linkMark = mark
        ? (state.selection.$from.marks() || []).find(m => m.type === mark)
        : null
      post({ type: 'insertLink', href: linkMark?.attrs.href ?? null })
    }
  })

  // ── Footnote tooltip ─────────────────────────────────────────────────────────

  const tooltip = document.getElementById('footnote-tooltip')

  function getFootnoteText(label) {
    let text = null
    editor.action(ctx => ctx.get(editorViewCtx)).state.doc.descendants(node => {
      if (node.type.name === 'footnoteDefinition' && node.attrs.label === label) {
        text = node.textContent
        return false
      }
    })
    return text
  }

  view.dom.addEventListener('mouseover', e => {
    const ref = e.target.closest('sup.footnote-ref[data-footnote]')
    if (!ref) { tooltip.hidden = true; return }
    const label = ref.getAttribute('data-footnote')
    const text  = label ? getFootnoteText(label) : null
    if (!text) { tooltip.hidden = true; return }
    tooltip.textContent = text
    tooltip.hidden = false
    const refRect = ref.getBoundingClientRect()
    tooltip.style.left = refRect.left + 'px'
    tooltip.style.top  = (refRect.bottom + 6) + 'px'
  })

  view.dom.addEventListener('mouseout', e => {
    if (!e.target.closest('sup.footnote-ref')) return
    tooltip.hidden = true
  })

  // Footnote reference click → scroll to the matching definition.
  view.dom.addEventListener('click', e => {
    const ref = e.target.closest('sup.footnote-ref[data-footnote]')
    if (!ref) return
    const label = ref.getAttribute('data-footnote')
    if (!label) return
    const target = document.querySelector(`[data-footnote-id="${label}"]`)
    target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  })

  // ── Footnote copy handler ─────────────────────────────────────────────────────
  //
  // When copying a selection that contains footnote references, the matching
  // definition text bodies are appended to the clipboard Markdown. Without
  // this, pasting into another document would produce dangling [^N] markers.

  view.dom.addEventListener('copy', e => {
    const state = editor.action(ctx => ctx.get(editorViewCtx)).state
    const { selection, doc } = state
    if (selection.empty) return

    const refLabels = []
    const seen = new Set()
    doc.nodesBetween(selection.from, selection.to, node => {
      if (node.type.name === 'footnoteReference' && !seen.has(node.attrs.label)) {
        seen.add(node.attrs.label)
        refLabels.push(node.attrs.label)
      }
    })
    if (refLabels.length === 0) return

    const defMap = new Map()
    doc.descendants(node => {
      if (node.type.name === 'footnoteDefinition' && seen.has(node.attrs.label)) {
        defMap.set(node.attrs.label, node.textContent)
      }
    })
    if (defMap.size === 0) return

    // Serialize the selected content as Markdown then append the definitions.
    const selectedMarkdown = editor.action(
      getMarkdown({ from: selection.from, to: selection.to })
    )
    const defLines = refLabels
      .filter(l => defMap.has(l))
      .map(l => `[^${l}]: ${defMap.get(l)}`)

    const fullMarkdown = selectedMarkdown.trimEnd() + '\n\n' + defLines.join('\n') + '\n'
    e.clipboardData.setData('text/plain', fullMarkdown)
    e.preventDefault()
  })
})()

// ── Scroll position tracking → Swift ─────────────────────────────────────────

let scrollDebounceTimer = null
const edEl = document.getElementById('editor')
edEl.addEventListener('scroll', () => {
  clearTimeout(scrollDebounceTimer)
  scrollDebounceTimer = setTimeout(() => {
    post({ type: 'scrollPositionChanged', scrollTop: Math.round(edEl.scrollTop) })
  }, 300)
})

// ── window.editorBridge — called from Swift via evaluateJavaScript ────────────

window.editorBridge = {
  // Replaces the editor content with a Markdown string. Does not mark the
  // document as dirty: addToHistory:false suppresses the listener's debounced
  // updated callback. Swift calls bridge.markClean() immediately after.
  setContent(markdown) {
    if (!editor) return
    editor.action(ctx => {
      const view   = ctx.get(editorViewCtx)
      const parser = ctx.get(parserCtx)
      const doc = parser(markdown || '')
      if (!doc) return
      const { state } = view
      const tr = state.tr
        .replace(0, state.doc.content.size, new Slice(doc.content, 0, 0))
      tr.setSelection(TextSelection.atStart(tr.doc))
      tr.setMeta(userInteractKey, false)
      tr.setMeta('addToHistory', false)
      view.dispatch(tr)

      if (!markdown || !markdown.trim()) {
        // Empty document: focus and mark interaction so typing starts immediately.
        view.focus()
        view.dispatch(
          view.state.tr
            .setMeta(userInteractKey, true)
            .setMeta('addToHistory', false)
        )
        updateCursor()
      }
    })
  },

  // Returns the current document as a Markdown string, with footnote IDs
  // renumbered to clean sequential integers in document order.
  getContent() {
    if (!editor) return ''
    return renumberMarkdown(editor.action(getMarkdown()))
  },

  toggleBold() {
    if (!editor) return
    editor.action(callCommand(toggleStrongCommand))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  toggleItalic() {
    if (!editor) return
    editor.action(callCommand(toggleEmphasisCommand))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  toggleBlockquote() {
    if (!editor) return
    editor.action(callCommand(wrapInBlockquoteCommand))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  toggleBulletList() {
    if (!editor) return
    editor.action(callCommand(wrapInBulletListCommand))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  toggleOrderedList() {
    if (!editor) return
    editor.action(callCommand(wrapInOrderedListCommand))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  // level 0 → paragraph; 1–3 → heading.
  // wrapInHeadingCommand internally calls setBlockType(paragraph) when level < 1.
  setHeading(level) {
    if (!editor) return
    editor.action(callCommand(wrapInHeadingCommand, level))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  setLink(url) {
    if (!editor) return
    editor.action(callCommand(updateLinkCommand, { href: url }))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
    sendStateUpdate()
  },

  // toggleMark from prosemirror-commands removes the mark when it is active,
  // which is the correct behaviour for an explicit "unset link" action.
  unsetLink() {
    if (!editor) return
    editor.action(ctx => {
      const view = ctx.get(editorViewCtx)
      const { state } = view
      const markType = state.schema.marks.link
      if (!markType) return
      toggleMark(markType)(state, view.dispatch)
      view.focus()
    })
    sendStateUpdate()
  },

  // Inserts a footnote reference at the cursor and a corresponding empty
  // definition at the end of the document, then moves the cursor into the
  // definition so the user can type its content immediately.
  addFootnoteReference() {
    if (!editor) return
    editor.action(ctx => {
      const view   = ctx.get(editorViewCtx)
      const { state } = view
      const { schema } = state
      const refType = schema.nodes.footnoteReference
      const defType = schema.nodes.footnoteDefinition
      if (!refType || !defType) return

      // Find the highest existing label to derive the next one.
      let maxLabel = 0
      state.doc.descendants(node => {
        if (node.type === refType) {
          const n = parseInt(node.attrs.label, 10)
          if (!isNaN(n) && n > maxLabel) maxLabel = n
        }
      })
      const newLabel = String(maxLabel + 1)

      const refNode  = refType.create({ label: newLabel })
      const emptyPara = schema.nodes.paragraph.create()
      const defNode  = defType.create({ label: newLabel }, emptyPara)

      // Insert reference at cursor, then append definition at end of document.
      // Using two separate steps so each insert can reference the updated doc.
      let tr = state.tr.replaceSelectionWith(refNode)
      tr = tr.insert(tr.doc.content.size, defNode)

      // Position cursor inside the new definition's paragraph.
      // defNode structure: [defOpen][paraOpen][content…][paraClose][defClose]
      // defStart + 2 lands at the start of the paragraph's content.
      const defStart = tr.doc.content.size - defNode.nodeSize
      tr = tr.setSelection(TextSelection.create(tr.doc, defStart + 2))

      view.dispatch(tr)
      view.focus()
    })
  },

  copyAll() {
    if (!editor) return
    const markdown = editor.action(getMarkdown())
    post({ type: 'copyAll', text: markdown })
    const btn = document.getElementById('copy-btn')
    if (btn) {
      btn.classList.add('copy-confirmed')
      setTimeout(() => btn.classList.remove('copy-confirmed'), 600)
    }
  },

  setAutoScrollMode(m) {
    autoScrollMode = m
    const ed = document.getElementById('editor')
    ed.style.paddingBottom = m === 'centered' ? '50vh' : ''
  },

  // callAsyncJavaScript is used for this method (not evaluateJavaScript)
  // because the base64 payload can be large. Do not swap these in Swift.
  insertImage(src) {
    if (!editor) return
    editor.action(callCommand(insertImageCommand, { src, alt: '' }))
    editor.action(ctx => ctx.get(editorViewCtx).focus())
  },

  searchAndHighlight(query) {
    if (!editor) return
    searchRanges = []
    const view = editor.action(ctx => ctx.get(editorViewCtx))
    if (!query) {
      view.dispatch(view.state.tr.setMeta(searchKey, 'clear'))
      return
    }
    const q = query.toLowerCase()
    view.state.doc.descendants((node, pos) => {
      if (node.type.name !== 'text') return
      const text = node.text.toLowerCase()
      let idx = 0
      while (idx < text.length) {
        const found = text.indexOf(q, idx)
        if (found === -1) break
        searchRanges.push({ from: pos + found, to: pos + found + query.length })
        idx = found + 1
      }
    })
    view.dispatch(view.state.tr.setMeta(searchKey, searchRanges))
  },

  scrollToSearchResult(index) {
    if (!editor || index < 0 || index >= searchRanges.length) return
    const { from } = searchRanges[index]
    const view    = editor.action(ctx => ctx.get(editorViewCtx))
    const coords  = view.coordsAtPos(from)
    const ed      = document.getElementById('editor')
    const edRect  = ed.getBoundingClientRect()
    const scrollTarget = ed.scrollTop + (coords.top - edRect.top) - ed.clientHeight / 3
    ed.scrollTo({ top: Math.max(0, scrollTarget), behavior: 'smooth' })
  },

  clearSearchHighlights() {
    if (!editor) return
    searchRanges = []
    const view = editor.action(ctx => ctx.get(editorViewCtx))
    view.dispatch(view.state.tr.setMeta(searchKey, 'clear'))
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

// ── Exposed globals for toolbarInitJS ─────────────────────────────────────────
//
// toolbarInitJS is injected via WKUserScript and has no access to this
// module's imports. These window properties are the bridge.

// Returns a computed active-state object for updating the toolbar. Returns null
// before the editor is ready, which guards the setInterval in toolbarInitJS.
window.__ft_getActiveState = () => {
  if (!editor) return null
  const state = editor.action(ctx => ctx.get(editorViewCtx).state)
  const interacted = userInteractKey.getState(state)
  return {
    interacted,
    bold:        interacted && isMarkActive(state, 'strong'),
    italic:      interacted && isMarkActive(state, 'emphasis'),
    blockquote:  interacted && isBlockTypeActive(state, 'blockquote'),
    link:        interacted && isMarkActive(state, 'link'),
    heading:     interacted ? getActiveHeadingLevel(state) : 0,
    bulletList:  interacted && isBlockTypeActive(state, 'bullet_list'),
    orderedList: interacted && isBlockTypeActive(state, 'ordered_list'),
  }
}

// Returns true once the user has clicked to place the cursor.
window.__ft_userInteracted = () => {
  if (!editor) return false
  return userInteractKey.getState(
    editor.action(ctx => ctx.get(editorViewCtx).state)
  )
}

// Returns the href of the link mark at the cursor position, or null.
// Used by toolbarInitJS to pre-fill the link dialog when editing an existing link.
window.__ft_getLinkHref = () => {
  if (!editor) return null
  const state = editor.action(ctx => ctx.get(editorViewCtx).state)
  const markType = state.schema.marks.link
  if (!markType) return null
  const linkMark = (state.selection.$from.marks() || []).find(m => m.type === markType)
  return linkMark?.attrs.href ?? null
}

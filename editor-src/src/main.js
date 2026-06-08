import {
  Editor,
  rootCtx,
  editorViewCtx,
  editorStateCtx,
  schemaCtx,
} from '@milkdown/core'
import {
  commonmark,
  toggleStrongCommand,
  toggleEmphasisCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand,
  wrapInHeadingCommand,
  turnIntoTextCommand,
  toggleLinkCommand,
  insertImageCommand,
} from '@milkdown/preset-commonmark'
import { gfm } from '@milkdown/preset-gfm'
import { history } from '@milkdown/plugin-history'
import { listener, listenerCtx } from '@milkdown/plugin-listener'
import { callCommand, getMarkdown, replaceAll, $prose } from '@milkdown/utils'
import { Plugin, PluginKey, TextSelection } from '@milkdown/prose/state'
import { DecorationSet, Decoration } from '@milkdown/prose/view'

// Swift bridge

function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

// Search highlight (ProseMirror decoration plugin)

const searchKey = new PluginKey('searchHighlight')
let searchRanges = []

const searchHighlightPlugin = new Plugin({
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
})

// User interaction tracking (ProseMirror plugin)
//
// Gates the custom cursor display and keyboard input until the user has
// clicked to deliberately place the cursor.

const userInteractKey = new PluginKey('userInteract')

const userInteractPlugin = new Plugin({
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
    handleKeyDown(view) {
      return !userInteractKey.getState(view.state)
    },
    handleClick(view) {
      if (!userInteractKey.getState(view.state)) {
        view.dispatch(view.state.tr.setMeta(userInteractKey, true))
      }
      updateCursor()
      return false
    },
  },
})

// Wrap as Milkdown plugins via $prose

const searchHighlightMilkdownPlugin = $prose(ctx => searchHighlightPlugin)
const userInteractMilkdownPlugin    = $prose(ctx => userInteractPlugin)

// Editor (module-level ref; assigned after create() resolves)

let editor = null

async function initEditor() {
  editor = await Editor.make()
    .config(ctx => {
      ctx.set(rootCtx, document.getElementById('editor'))
    })
    .config(ctx => {
      ctx.get(listenerCtx)
        .mounted(() => {
          // editor variable is null here (mounted fires during create()),
          // but editorReady just posts a message — no editor access needed.
          post({ type: 'editorReady' })
        })
        .updated(() => {
          // Fires after user edits, always after create() resolves.
          post({ type: 'documentChanged' })
          sendStateUpdate()
          requestAnimationFrame(doCenteredScroll)
          updateCursor()
        })
        .selectionUpdated(() => {
          sendStateUpdate()
          updateCursor()
        })
        .focus(() => { updateCursor() })
        .blur(()  => { updateCursor() })
    })
    .use(commonmark)
    .use(gfm)
    .use(history)
    .use(listener)
    .use(searchHighlightMilkdownPlugin)
    .use(userInteractMilkdownPlugin)
    .create()

  // Expose for toolbarInitJS
  window.__ft_userInteracted = () => {
    const view = editor.ctx.get(editorViewCtx)
    return userInteractKey.getState(view.state)
  }

  // Returns current formatting state as a plain object for toolbar polling.
  window.__ft_stateSnapshot = () => {
    const view   = editor.ctx.get(editorViewCtx)
    const state  = view.state
    const schema = state.schema
    const { $from, from, to, empty } = state.selection

    function markActive(markType) {
      if (!markType) return false
      if (empty) return !!markType.isInSet(state.storedMarks || $from.marks())
      return state.doc.rangeHasMark(from, to, markType)
    }

    function headingLevel() {
      for (let d = $from.depth; d >= 0; d--) {
        const node = $from.node(d)
        if (node.type.name === 'heading') return node.attrs.level || 0
      }
      return 0
    }

    function ancestorIs(typeName) {
      for (let d = $from.depth; d >= 0; d--) {
        if ($from.node(d).type.name === typeName) return true
      }
      return false
    }

    return {
      bold:        markActive(schema.marks['strong']),
      italic:      markActive(schema.marks['em']),
      heading:     headingLevel(),
      bulletList:  ancestorIs('bullet_list'),
      orderedList: ancestorIs('ordered_list'),
      blockquote:  ancestorIs('blockquote'),
      linkActive:  markActive(schema.marks['link']),
    }
  }

  // Returns the href of the link mark at the cursor (or null).
  window.__ft_getLinkHref = () => {
    const view  = editor.ctx.get(editorViewCtx)
    const state = view.state
    const mark  = state.schema.marks['link']
    if (!mark) return null
    const { $from, empty } = state.selection
    if (empty) {
      const found = mark.isInSet(state.storedMarks || $from.marks())
      return found ? found.attrs.href : null
    }
    return null
  }

  // Cursor element (appended after editor mount so ProseMirror's DOM is ready)
  const cur = document.createElement('div')
  cur.id = 'custom-cursor'
  document.getElementById('editor').appendChild(cur)
  window.__ft_cursorEl = cur

  setupEditorDOMListeners()
  setupBridge()

  // Scroll position tracking → Swift
  const edEl = document.getElementById('editor')
  let scrollTimer = null
  edEl.addEventListener('scroll', () => {
    clearTimeout(scrollTimer)
    scrollTimer = setTimeout(() => {
      post({ type: 'scrollPositionChanged', scrollTop: Math.round(edEl.scrollTop) })
    }, 300)
  })
}

// State updates → Swift

function sendStateUpdate() {
  if (!editor || !window.__ft_stateSnapshot) return
  const snap = window.__ft_stateSnapshot()
  post({
    type:        'stateUpdate',
    bold:        snap.bold        || false,
    italic:      snap.italic      || false,
    heading:     snap.heading     || 0,
    bulletList:  snap.bulletList  || false,
    orderedList: snap.orderedList || false,
    blockquote:  snap.blockquote  || false,
    linkActive:  snap.linkActive  || false,
  })
}

// Custom cursor

function updateCursor() {
  const cur = window.__ft_cursorEl
  if (!cur || !editor) return
  const view = editor.ctx.get(editorViewCtx)
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
    void cur.offsetWidth
    cur.classList.add('blinking')
  } catch {
    cur.style.display = 'none'
  }
}

// Auto-scroll (centered mode)

let autoScrollMode = 'regular'

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
  ed.scrollTo({ top: Math.max(0, ed.scrollTop + (cursorCenterY - edCenterY)), behavior: 'smooth' })
}

// Footnote tooltip and DOM event listeners

function setupEditorDOMListeners() {
  const edEl    = document.getElementById('editor')
  const tooltip = document.getElementById('footnote-tooltip')

  function getFootnoteText(label) {
    if (!editor) return null
    let text = null
    const view = editor.ctx.get(editorViewCtx)
    view.state.doc.descendants(node => {
      if (node.type.name === 'footnote_definition' && node.attrs.label === label) {
        text = node.textContent
        return false
      }
    })
    return text
  }

  edEl.addEventListener('mouseover', e => {
    const ref = e.target.closest('sup[data-type="footnote_reference"]')
    if (!ref) { tooltip.hidden = true; return }
    const text = getFootnoteText(ref.dataset.label)
    if (!text) { tooltip.hidden = true; return }
    tooltip.textContent = text
    tooltip.hidden = false
    const r = ref.getBoundingClientRect()
    tooltip.style.left = r.left + 'px'
    tooltip.style.top  = (r.bottom + 6) + 'px'
  })

  edEl.addEventListener('mouseout', e => {
    if (!e.target.closest('sup[data-type="footnote_reference"]')) return
    tooltip.hidden = true
  })

  // Footnote reference click → scroll to its definition
  edEl.addEventListener('click', e => {
    const ref = e.target.closest('sup[data-type="footnote_reference"]')
    if (!ref) return
    const label = ref.dataset.label
    if (!label) return
    document.querySelector(`dl[data-type="footnote_definition"][data-label="${label}"]`)
      ?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  })

  // ⌘+click opens hyperlinks
  edEl.addEventListener('click', e => {
    if (!e.metaKey) return
    const a = e.target.closest('a[href]')
    if (!a) return
    e.preventDefault()
    post({ type: 'openURL', url: a.href })
  })

  // ⌘K opens the hyperlink dialog
  edEl.addEventListener('keydown', e => {
    if (e.key !== 'k' || !e.metaKey) return
    e.preventDefault()
    const href = window.__ft_getLinkHref ? window.__ft_getLinkHref() : null
    post({ type: 'insertLink', href: href || null })
  })

  // Footnote clipboard — copy side
  // If the selection contains [^N] references, append their definition lines
  // to the clipboard so they survive paste elsewhere.
  edEl.addEventListener('copy', e => {
    if (!editor) return
    const view  = editor.ctx.get(editorViewCtx)
    const { selection } = view.state
    if (selection.empty) return

    const labels = new Set()
    view.state.doc.nodesBetween(selection.from, selection.to, node => {
      if (node.type.name === 'footnote_reference') labels.add(node.attrs.label)
    })
    if (labels.size === 0) return

    const fullMd   = editor.action(getMarkdown())
    const defLines = []
    for (const label of labels) {
      const prefix = `[^${label}]:`
      for (const line of fullMd.split('\n')) {
        if (line.startsWith(prefix)) defLines.push(line)
      }
    }
    if (defLines.length === 0) return

    const selText = view.state.doc.textBetween(selection.from, selection.to, '\n')
    e.clipboardData.setData('text/plain', selText + '\n\n' + defLines.join('\n'))
    e.preventDefault()
  })
}

// Insert footnote reference
//
// Scans the document for the highest integer label already in use, picks the
// next one, inserts a reference inline at the cursor, and appends an empty
// definition block at the end of the document.

function addFootnoteReference() {
  if (!editor) return
  const view   = editor.ctx.get(editorViewCtx)
  const state  = view.state
  const schema = state.schema
  const refType = schema.nodes['footnote_reference']
  const defType = schema.nodes['footnote_definition']
  const paraType = schema.nodes['paragraph']
  if (!refType || !defType || !paraType) return

  const usedLabels = new Set()
  state.doc.descendants(node => {
    if (node.type === refType || node.type === defType) usedLabels.add(node.attrs.label)
  })
  let next = 1
  while (usedLabels.has(String(next))) next++
  const label = String(next)

  const tr = state.tr
  tr.replaceSelectionWith(refType.create({ label }))
  tr.insert(tr.doc.content.size, defType.create({ label }, paraType.create()))
  view.dispatch(tr)
  view.focus()
}

// window.editorBridge — called from Swift via evaluateJavaScript

function setupBridge() {
  window.editorBridge = {
    setContent(n) {
      // n is a Markdown string
      editor.action(replaceAll(n))
      const view = editor.ctx.get(editorViewCtx)
      view.dispatch(
        view.state.tr
          .setSelection(TextSelection.atStart(view.state.doc))
          .setMeta(userInteractKey, false)
      )
      // Empty document: focus immediately so the user can start typing
      if (!editor.action(getMarkdown()).trim()) {
        const v = editor.ctx.get(editorViewCtx)
        v.dispatch(
          v.state.tr
            .setSelection(TextSelection.atEnd(v.state.doc))
            .setMeta(userInteractKey, true)
        )
        v.focus()
        updateCursor()
      }
    },

    getContent() {
      return editor.action(getMarkdown())
    },

    toggleBold()        { editor.action(callCommand(toggleStrongCommand.key));    sendStateUpdate() },
    toggleItalic()      { editor.action(callCommand(toggleEmphasisCommand.key));  sendStateUpdate() },
    toggleBlockquote()  { editor.action(callCommand(wrapInBlockquoteCommand.key)); sendStateUpdate() },
    toggleBulletList()  { editor.action(callCommand(wrapInBulletListCommand.key)); sendStateUpdate() },
    toggleOrderedList() { editor.action(callCommand(wrapInOrderedListCommand.key)); sendStateUpdate() },

    setHeading(level) {
      if (level === 0) {
        editor.action(callCommand(turnIntoTextCommand.key))
      } else {
        editor.action(callCommand(wrapInHeadingCommand.key, level))
      }
      sendStateUpdate()
    },

    setLink(url) {
      editor.action(callCommand(toggleLinkCommand.key, { href: url }))
      sendStateUpdate()
    },
    unsetLink() {
      editor.action(callCommand(toggleLinkCommand.key))
      sendStateUpdate()
    },

    addFootnoteReference() { addFootnoteReference() },

    copyAll() {
      const view = editor.ctx.get(editorViewCtx)
      post({ type: 'copyAll', text: view.state.doc.textContent, html: view.dom.innerHTML })
      const btn = document.getElementById('copy-btn')
      if (btn) {
        btn.classList.add('copy-confirmed')
        setTimeout(() => btn.classList.remove('copy-confirmed'), 600)
      }
    },

    insertImage(src) {
      editor.action(callCommand(insertImageCommand.key, { src, alt: '' }))
    },

    setAutoScrollMode(m) {
      autoScrollMode = m
      document.getElementById('editor').style.paddingBottom = m === 'centered' ? '50vh' : ''
    },

    searchAndHighlight(query) {
      searchRanges = []
      const view = editor.ctx.get(editorViewCtx)
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
      const view   = editor.ctx.get(editorViewCtx)
      const { from } = searchRanges[index]
      const coords = view.coordsAtPos(from)
      const ed     = document.getElementById('editor')
      const edRect = ed.getBoundingClientRect()
      ed.scrollTo({ top: Math.max(0, ed.scrollTop + (coords.top - edRect.top) - ed.clientHeight / 3), behavior: 'smooth' })
    },

    clearSearchHighlights() {
      searchRanges = []
      if (!editor) return
      const view = editor.ctx.get(editorViewCtx)
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
}

initEditor()

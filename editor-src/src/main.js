import { Editor, Extension } from '@tiptap/core'
import { Document } from '@tiptap/extension-document'
import StarterKit from '@tiptap/starter-kit'
import Underline from '@tiptap/extension-underline'
import Image from '@tiptap/extension-image'
import Placeholder from '@tiptap/extension-placeholder'
import Link from '@tiptap/extension-link'
import TaskList from '@tiptap/extension-task-list'
import TaskItem from '@tiptap/extension-task-item'
import CharacterCount from '@tiptap/extension-character-count'
import TextDirection from 'tiptap-text-direction'
import { Footnote, FootnoteReference, Footnotes } from 'tiptap-footnotes'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { DOMParser as PMDOMParser, DOMSerializer } from '@tiptap/pm/model'
import { DecorationSet, Decoration } from '@tiptap/pm/view'

// Swift bridge

function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

// Search highlight extension (ProseMirror decoration plugin)

const searchKey = new PluginKey('searchHighlight')
let searchRanges = []

const SearchHighlightExtension = Extension.create({
  name: 'searchHighlight',
  addProseMirrorPlugins() {
    return [new Plugin({
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
    })]
  },
})

// User interaction tracking (ProseMirror plugin)
//
// Tracks whether the user has clicked to place the cursor yet.
// Gates the custom cursor display and toolbar active-state indicators,
// and blocks keystrokes until the first deliberate click.

const userInteractKey = new PluginKey('userInteract')

const UserInteractionExtension = Extension.create({
  name: 'userInteract',
  addProseMirrorPlugins() {
    return [new Plugin({
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
        // Called after ProseMirror has fully processed a click and placed the selection.
        // Two cases arise:
        //   (a) Pointer transaction fired during mousedown → userInteracted already true.
        //   (b) Click did not change the selection (e.g. clicking in an empty paragraph
        //       already at position 1) → ProseMirror skips the pointer transaction →
        //       userInteracted is still false after mousedown.
        // In case (b) we dispatch our own transaction here to set userInteracted.
        handleClick(view) {
          if (!userInteractKey.getState(view.state)) {
            view.dispatch(view.state.tr.setMeta(userInteractKey, true))
          }
          updateCursor()
          return false
        },
      },
    })]
  },
})

// Footnote clipboard (copy + paste)
//
// Two problems solved here:
//
//   PASTE: tiptap-footnotes' appendTransaction rebuilds the footnotes
//   container after every paste, but the pasted <ol class="footnotes"> is
//   dropped by ProseMirror's schema fitting (only one footnotes? allowed at
//   doc end). So data-ids never match → every footnote becomes an empty
//   paragraph. Fix: extract content from the raw clipboard HTML before
//   TipTap processes it, then fill the (empty) rebuilt footnotes in a
//   deferred transaction once FootnoteRules has finished.
//
//   COPY (Cmd+C on a selection): the footnotes container lives outside any
//   selection, so definitions are never included. Fix: intercept the copy
//   event and append the referenced definitions to the clipboard HTML.

const pendingFootnoteContent = new Map() // data-id → inner HTML of footnote content

const FootnoteClipboardExtension = Extension.create({
  name: 'footnoteClipboard',
  addProseMirrorPlugins() {
    const ext = this
    return [new Plugin({
      key: new PluginKey('footnoteClipboard'),
      props: {
        // Paste side
        // Runs before TipTap parses the clipboard HTML. Stash footnote
        // content so we can restore it after FootnoteRules clears it.
        transformPastedHTML(html) {
          pendingFootnoteContent.clear()
          const div = document.createElement('div')
          div.innerHTML = html
          div.querySelectorAll('ol.footnotes li[data-id]').forEach(li => {
            li.querySelectorAll('a.footnote-backlink').forEach(a => a.remove())
            pendingFootnoteContent.set(li.getAttribute('data-id'), li.innerHTML.trim())
          })
          div.querySelectorAll('ol.footnotes').forEach(ol => ol.remove())
          return div.innerHTML
        },

        // Copy side
        // When a selection contains footnote references, append their
        // definitions to the clipboard HTML so they survive paste.
        handleDOMEvents: {
          copy(view, event) {
            const { selection } = view.state
            if (selection.empty) return false

            const referencedIds = new Set()
            view.state.doc.nodesBetween(selection.from, selection.to, node => {
              if (node.type.name === 'footnoteReference')
                referencedIds.add(node.attrs['data-id'])
            })
            if (referencedIds.size === 0) return false

            const footnoteMap = new Map()
            view.state.doc.descendants(node => {
              if (node.type.name === 'footnote')
                footnoteMap.set(node.attrs['data-id'], node)
            })

            const matchedFn = [...referencedIds].map(id => footnoteMap.get(id)).filter(Boolean)
            if (matchedFn.length === 0) return false

            const serializer = DOMSerializer.fromSchema(view.state.schema)
            const wrap = document.createElement('div')
            wrap.appendChild(serializer.serializeFragment(selection.content().content))

            const ol = document.createElement('ol')
            ol.className = 'footnotes'
            matchedFn.forEach(fn => ol.appendChild(serializer.serializeNode(fn)))
            wrap.appendChild(ol)

            event.clipboardData.setData('text/html', wrap.innerHTML)
            event.clipboardData.setData('text/plain', wrap.textContent)
            event.preventDefault()
            return true
          }
        }
      },

      // Deferred paste fill-in
      // Return null — we must not fight FootnoteRules' simultaneous
      // appendTransaction over the same footnotes container positions.
      // Instead, schedule a fresh dispatch after FootnoteRules finishes.
      appendTransaction(transactions, _oldState, _newState) {
        if (pendingFootnoteContent.size === 0) return null
        if (!transactions.some(tr => tr.getMeta('paste'))) return null

        const map = new Map(pendingFootnoteContent)
        pendingFootnoteContent.clear()

        setTimeout(() => {
          const state = ext.editor.state
          const replacements = []
          state.doc.descendants((node, pos) => {
            if (node.type.name !== 'footnote') return
            const id = node.attrs['data-id']
            if (!map.has(id) || node.textContent.length > 0) return
            replacements.push({ pos, size: node.nodeSize, id })
          })
          if (replacements.length === 0) return

          const tr = state.tr
          for (let i = replacements.length - 1; i >= 0; i--) {
            const { pos, size, id } = replacements[i]
            const contentDiv = document.createElement('div')
            contentDiv.innerHTML = map.get(id)
            const parsed = PMDOMParser.fromSchema(state.schema).parse(contentDiv)
            tr.replaceWith(pos + 1, pos + size - 1, parsed.content)
          }
          ext.editor.view.dispatch(tr)
        }, 0)

        return null
      }
    })]
  }
})

// Editor

const editor = new Editor({
  element: document.getElementById('editor'),
  extensions: [
    // Custom Document schema allows a footnotes node at the end
    Document.extend({ content: 'block+ footnotes?' }),
    StarterKit.configure({
      document: false,
      heading: { levels: [1, 2, 3] },
    }),
    Underline,
    Image.configure({ inline: false }),
    Placeholder.configure({ placeholder: '' }),
    Link.configure({ openOnClick: false }),
    TaskList,
    TaskItem.configure({ nested: true }),
    CharacterCount,
    TextDirection,
    Footnote,
    FootnoteReference,
    Footnotes,
    FootnoteClipboardExtension,
    UserInteractionExtension,
    SearchHighlightExtension,
  ],
  onUpdate() {
    post({ type: 'documentChanged' })
    sendStateUpdate()
    requestAnimationFrame(doCenteredScroll)
    updateCursor()
  },
  onSelectionUpdate() {
    sendStateUpdate()
    updateCursor()
  },
  onFocus() {
    updateCursor()
  },
  onBlur() {
    updateCursor()
  },
  onCreate() {
    post({ type: 'editorReady' })
  },
})

window.editor = editor
// Lets toolbarInitJS (which has no access to userInteractKey) ask whether the user has
// placed the cursor yet. Returns false until a click (or empty-blob auto-focus) sets
// userInteracted, keeping the toolbar in its neutral state before first interaction.
window.__ft_userInteracted = () => userInteractKey.getState(editor.state)

// State updates → Swift

function sendStateUpdate() {
  post({
    type: 'stateUpdate',
    bold:        editor.isActive('bold'),
    italic:      editor.isActive('italic'),
    underline:   editor.isActive('underline'),
    heading:     editor.isActive('heading', { level: 1 }) ? 1
               : editor.isActive('heading', { level: 2 }) ? 2
               : editor.isActive('heading', { level: 3 }) ? 3 : 0,
    bulletList:  editor.isActive('bulletList'),
    orderedList: editor.isActive('orderedList'),
    blockquote:  editor.isActive('blockquote'),
    linkActive:  editor.isActive('link'),
  })
}

// Custom cursor

const cur = document.createElement('div')
cur.id = 'custom-cursor'
document.getElementById('editor').appendChild(cur)

function updateCursor() {
  if (!editor.isFocused || !editor.state.selection.empty) {
    cur.style.display = 'none'
    return
  }
  if (!userInteractKey.getState(editor.state)) {
    cur.style.display = 'none'
    return
  }
  const pos = editor.state.selection.$head.pos
  try {
    const coords  = editor.view.coordsAtPos(pos)
    const domPos  = editor.view.domAtPos(pos)
    let node      = domPos.node
    if (node.nodeType === 3) node = node.parentElement
    const style   = getComputedStyle(node)
    const fontSize  = parseFloat(style.fontSize) || 22
    const cursorH   = fontSize * 1.5
    const charH     = coords.bottom - coords.top
    const ed        = document.getElementById('editor')
    const edRect    = ed.getBoundingClientRect()
    const textCenter = coords.top + (charH / 2) - edRect.top + ed.scrollTop
    const top  = textCenter - (cursorH / 2)
    const left = coords.left - edRect.left
    cur.style.top    = top + 'px'
    cur.style.left   = left + 'px'
    cur.style.height = cursorH + 'px'
    cur.style.display = 'block'
    cur.classList.remove('blinking')
    void cur.offsetWidth  // force reflow to restart animation
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
  const ed        = document.getElementById('editor')
  const edRect    = ed.getBoundingClientRect()
  const cursorCenterY = rect.top + rect.height / 2
  const edCenterY     = edRect.top + ed.clientHeight / 2
  if (cursorCenterY <= edCenterY) return
  const targetScroll = ed.scrollTop + (cursorCenterY - edCenterY)
  ed.scrollTo({ top: Math.max(0, targetScroll), behavior: 'smooth' })
}

// Footnote tooltip

const tooltip = document.getElementById('footnote-tooltip')

function getFootnoteText(id) {
  let text = null
  editor.state.doc.descendants(node => {
    if (node.type.name === 'footnote' &&
        (node.attrs.id === id || node.attrs['data-id'] === id || node.attrs['footnote-id'] === id)) {
      text = node.textContent
      return false
    }
  })
  return text
}

editor.view.dom.addEventListener('mouseover', e => {
  const ref = e.target.closest('[data-type="footnoteReference"]')
  if (!ref) { tooltip.hidden = true; return }
  const id = ref.getAttribute('data-id') || ref.getAttribute('data-footnote-id') || ref.getAttribute('data-footnote')
  const text = id ? getFootnoteText(id) : null
  if (!text) { tooltip.hidden = true; return }
  tooltip.textContent = text
  tooltip.hidden = false
  const refRect = ref.getBoundingClientRect()
  tooltip.style.left = refRect.left + 'px'
  tooltip.style.top  = (refRect.bottom + 6) + 'px'
})

editor.view.dom.addEventListener('mouseout', e => {
  if (!e.target.closest('[data-type="footnoteReference"]')) return
  tooltip.hidden = true
})

// Footnote reference click → scroll to corresponding footnote body
editor.view.dom.addEventListener('click', e => {
  const ref = e.target.closest('[data-type="footnoteReference"]')
  if (!ref) return
  const id = ref.getAttribute('data-id') || ref.getAttribute('data-footnote-id') || ref.getAttribute('data-footnote')
  if (!id) return
  const target = document.querySelector(`[data-type="footnote"][data-id="${id}"]`)
            || document.querySelector(`[data-type="footnote"][data-footnote-id="${id}"]`)
            || document.querySelector(`[data-footnote-id="${id}"]`)
  target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
})

// ⌘+click opens a hyperlink in the system browser
editor.view.dom.addEventListener('click', e => {
  if (!e.metaKey) return
  const a = e.target.closest('a[href]')
  if (!a) return
  e.preventDefault()
  post({ type: 'openURL', url: a.href })
})

// ⌘K opens the hyperlink dialog (mirrors ⌘B/⌘I pattern: keydown on the editor DOM)
editor.view.dom.addEventListener('keydown', e => {
  if (e.key === 'k' && e.metaKey) {
    e.preventDefault()
    post({ type: 'insertLink', href: editor.getAttributes('link').href || null })
  }
})

// window.editorBridge — called from Swift via evaluateJavaScript

window.editorBridge = {
  setContent(n) {
    const doc = typeof n === 'string' ? JSON.parse(n) : n
    editor.commands.setContent(doc, false)
    // Reset selection to start (ProseMirror's replaceWith maps old selection to end)
    // and reset userInteracted so the cursor doesn't appear before the first click.
    editor.view.dispatch(
      editor.state.tr
        .setSelection(TextSelection.atStart(editor.state.doc))
        .setMeta(userInteractKey, false)
    )
    if (editor.isEmpty) {
      // Empty document: focus immediately so the user can start typing right away.
      editor.commands.focus('end')
      editor.view.dispatch(
        editor.state.tr.setMeta(userInteractKey, true)
      )
      updateCursor()
    }
  },
  toggleBold()        { editor.chain().focus().toggleBold().run();        sendStateUpdate() },
  toggleItalic()      { editor.chain().focus().toggleItalic().run();      sendStateUpdate() },
  toggleUnderline()   { editor.chain().focus().toggleUnderline().run();   sendStateUpdate() },
  toggleBlockquote()  { editor.chain().focus().toggleBlockquote().run();  sendStateUpdate() },
  toggleBulletList()  { editor.chain().focus().toggleBulletList().run();  sendStateUpdate() },
  toggleOrderedList() { editor.chain().focus().toggleOrderedList().run(); sendStateUpdate() },
  setHeading(level) {
    if (level === 0) editor.chain().focus().setParagraph().run()
    else editor.chain().focus().setHeading({ level }).run()
    sendStateUpdate()
  },
  setLink(url) {
    editor.chain().focus().setLink({ href: url }).run()
    sendStateUpdate()
  },
  unsetLink() {
    editor.chain().focus().unsetLink().run()
    sendStateUpdate()
  },
  addFootnoteReference() { editor.chain().focus().addFootnote().run() },
  copyAll() {
    post({ type: 'copyAll', text: editor.getText(), html: editor.getHTML() })
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
  insertImage(src) {
    editor.chain().focus().insertContent({ type: 'image', attrs: { src, alt: '' } }).run()
  },
  searchAndHighlight(query) {
    searchRanges = []
    if (!query) {
      editor.view.dispatch(editor.state.tr.setMeta(searchKey, 'clear'))
      return
    }
    const q = query.toLowerCase()
    editor.state.doc.descendants((node, pos) => {
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
    editor.view.dispatch(editor.state.tr.setMeta(searchKey, searchRanges))
  },
  scrollToSearchResult(index) {
    if (index < 0 || index >= searchRanges.length) return
    const { from } = searchRanges[index]
    const coords = editor.view.coordsAtPos(from)
    const ed = document.getElementById('editor')
    const edRect = ed.getBoundingClientRect()
    const scrollTarget = ed.scrollTop + (coords.top - edRect.top) - ed.clientHeight / 3
    ed.scrollTo({ top: Math.max(0, scrollTarget), behavior: 'smooth' })
  },
  clearSearchHighlights() {
    searchRanges = []
    editor.view.dispatch(editor.state.tr.setMeta(searchKey, 'clear'))
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

// Scroll position tracking → Swift

let scrollDebounceTimer = null
const edEl = document.getElementById('editor')
edEl.addEventListener('scroll', () => {
  clearTimeout(scrollDebounceTimer)
  scrollDebounceTimer = setTimeout(() => {
    post({ type: 'scrollPositionChanged', scrollTop: Math.round(edEl.scrollTop) })
  }, 300)
})

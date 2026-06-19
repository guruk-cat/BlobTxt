import { EditorView } from '@codemirror/view'
import { post } from './state.js'

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
export function goToHeading(view, fragment) {
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
export function openLink(href, view) {
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

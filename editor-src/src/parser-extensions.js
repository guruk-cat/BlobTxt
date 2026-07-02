import { parser as baseMarkdownParser } from '@lezer/markdown'
import { foldNodeProp } from '@codemirror/language'

// Lezer parser extension — footnote exclamation fix (cm-editor-customs.md §4)

/*
  "text![^ref]" makes the GFM Image parser fire on '![' and tag it as a muted
  processingInstruction, even with no trailing '(url)'. Running before the Image
  parser, this consumes the '!' as plain text (returns pos+1, no node) so the
  Image parser never fires and '[^ref]' is parsed normally.
*/
export const footnoteImageFix = {
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
export const plainBracketFix = {
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

export const footnoteDefFix = {
  parseBlock: [{
    name: 'LinkReference',
    leaf(cx, leaf) {
      if (/^\[\^[^\]]+\]:/.test(leaf.content)) return null
      return linkReferenceLeaf ? linkReferenceLeaf(cx, leaf) : null
    },
  }],
}

// Lezer parser extension — YAML frontmatter block

/*
  Without frontmatter support, a "title: x" line above a closing "---" reads as a
  setext heading (text + "---" underline = H2), coloring the block as a heading.
  This claims a "---...---" block at document start before HorizontalRule/setext
  can, tagging it as an unstyled Frontmatter node so it renders as body text.
*/
export const frontmatter = {
  defineNodes: [{ name: 'Frontmatter', block: true }],
  parseBlock: [{
    name: 'Frontmatter',
    before: 'HorizontalRule',
    parse(cx, line) {
      if (cx.lineStart !== 0 || line.text !== '---') return false
      const start = cx.lineStart
      while (cx.nextLine()) {
        if (line.text === '---') {
          const end = cx.lineStart + line.text.length
          cx.nextLine()
          cx.addElement(cx.elt('Frontmatter', start, end))
          return true
        }
      }
      return false  // no closing fence — let normal parsing handle it
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
export const headingOnlyFold = {
  props: [
    foldNodeProp.add(type => type.is('Block') ? () => null : undefined),
  ],
}

import { HighlightStyle } from '@codemirror/language'
import { tags, Tag, styleTags } from '@lezer/highlight'

/*
  The parser tags every mark with the single processingInstruction tag, but two
  groups need different colors: brackets/parens should recede (--text-muted)
  while list bullets, emphasis delimiters, and quote chevrons should stand out
  (--meta-indication). A styleTags override re-tags just the conspicuous node
  types to a custom tag; the rest stay on processingInstruction. (§5.1)
*/
const conspicuousMark = Tag.define()

export const conspicuousMarkStyle = {
  props: [
    styleTags({
      'ListMark EmphasisMark QuoteMark': conspicuousMark,
    }),
  ],
}

// Token-level colors and weights. Heading font sizes are NOT set here because
// they scale with the user's font size preference and must change together with
// .cm-content — both are handled by the fontCompartment theme instead.
export const highlightStyle = HighlightStyle.define([
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

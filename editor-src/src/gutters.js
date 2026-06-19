import { gutter, GutterMarker } from '@codemirror/view'
import { StateField } from '@codemirror/state'

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

export const wordMilestones = StateField.define({
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

export const wordCountGutter = gutter({
  class: 'cm-wordcount-gutter',
  lineMarker(view, line) {
    const n = view.state.field(wordMilestones)[view.state.doc.lineAt(line.from).number]
    return n ? new MilestoneMarker(n) : null
  },
  lineMarkerChange(update) { return update.docChanged },
})

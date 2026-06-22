# Results: Pandoc citeproc footnotes vs. hand-written GFM footnotes

## 1. Environment

- Pandoc 3.10 (Features: +server +lua; Lua 5.4), using the built-in `--citeproc`.
- Bibliography: `refs.json` (CSL-JSON, two fake-but-valid entries `key1`, `key2`).
- Notes style: `chicago-notes-bibliography.csl` (`class="note"`).
- Control style: `chicago-author-date.csl`.
- Date run: 2026-06-22.

## 2. Method

One source file (`test.md`) was run twice, swapping only the CSL style via `--csl`:

```bash
pandoc test.md --citeproc --csl chicago-notes-bibliography.csl -o test-notes.html
pandoc test.md --citeproc --csl chicago-author-date.csl     -o test-authordate.html
```

`test.md` deliberately includes more than the question strictly needs, so that unplanned behavior could surface. It contains the following cases:

- Hand-written notes at the beginning, middle, and end (`[^alpha]`, `[^beta]`, `[^delta]`).
- A lone citation with no marker nearby (`[@key1]`).
- A same-sentence adjacency case where `[^beta]` and `[@key2]` sit in one sentence.
- A reference-before-definition case where `[^gamma]` is referenced near a second `[@key1]`, but its `[^gamma]:` definition is written late.
- Definitions written out of order in source, with `[^beta]:` placed before `[^alpha]:`.

Notes were named `alpha`/`beta`/`gamma`/`delta` rather than `[^1]`–`[^4]` so each source marker could be traced to its final output number. All output numbers are assigned by citeproc.

Both runs exited `0` with no errors or warnings.

## 3. Findings
### 3.1. Notes style: the two streams merge into one renumbered sequence

The hand-written and citeproc-generated footnotes merge into a single, correctly renumbered sequence in document reference-order. They are indistinguishable in the output, sharing the same `<ol>`, the same markup, and the same back-links.

| Output # | Source origin | Type |
| --- | --- | --- |
| 1 | `[^alpha]` (beginning) | hand-written |
| 2 | `[@key1]` (middle, lone) | citeproc |
| 3 | `[^beta]` (same-sentence) | hand-written |
| 4 | `[@key2]` (same-sentence) | citeproc |
| 5 | `[^gamma]` (ref-before-def) | hand-written |
| 6 | `[@key1]` (ref-before-def, repeat) | citeproc |
| 7 | `[^delta]` (end) | hand-written |

This answers the brief's four questions. The streams are merged into one renumbered sequence rather than kept separate. Numbering follows strict source reference-order. In the same-sentence case both notes render with no drop or duplication, and left-to-right source order decides the order, so `[^beta]` became 3 and `[@key2]` became 4. Nothing broke.

### 3.2. Numbering follows reference order, not definition order

`[^beta]:` was defined before `[^alpha]:` in source, and `[^gamma]:` was defined late. Final numbering still followed reference position: alpha is 1, beta is 3, gamma is 5. citeproc and GFM footnotes agree on this, so where a definition sits in the source has no effect on its number.

### 3.3. Repeat citations are stateful (unplanned finding)

Output note 6, the second occurrence of `[@key1]`, auto-shortened to "Aldgate, The First Fictional Treatise." against the full form in note 2. citeproc tracks subsequent citations across the entire merged stream and applies the notes style's short-form rules. Repeat-citation rendering is therefore stateful across the whole document, not decided per citation.

### 3.4. The author-date control is safe

With `chicago-author-date.csl`, citations stay inline as `(Aldgate 2019)`, `(Bromfield 2021)`, and `(Aldgate 2019)`, generating no footnotes. The footnotes section contains exactly the four hand-written notes, numbered 1 through 4 and completely unaffected. The two are cleanly separable in this mode.

## 4. Takeaway for BlobTxt

Under a notes style, `[^N]` and `[@key]` are not independent numbering spaces. citeproc owns the entire footnote sequence and interleaves and renumbers hand-written notes into it. Any UI that shows footnote numbers, such as gutter markers, an outline, or counts, must read from the rendered output rather than counting `[^N]` tokens in source, because the source numbers are meaningless once citeproc runs. Under an author-date style the footnotes and citations are independent and the source `[^N]` numbering is preserved. Repeat citations are stateful, so the same `[@key]` can render differently on its second use.

## 5. Artifacts

- `test.md`, the source document.
- `refs.json`, the CSL-JSON bibliography.
- `chicago-notes-bibliography.csl` and `chicago-author-date.csl`, the styles.
- `test-notes.html` and `test-authordate.html`, the rendered outputs.

# Results: Chicago notes footnotes with citations inside footnotes

The intended usage is predominantly Chicago-style footnotes where each citation lives **inside** a hand-written `[^fn]` footnote definition. Example:

```markdown
Some text in which I cite an author.[^fn1]

[^fn1]: [@key1, para. 6].
```

## 1. Environment

- Pandoc 3.10, built-in `--citeproc`.
- Bibliography: `refs.json` (same two fake entries `key1`, `key2`).
- Notes style: `chicago-notes-bibliography.csl`.
- Date run: 2026-06-30.

## 2. Findings

### 2.1. Citations inside a footnote do NOT generate a second footnote

This is the headline result and the reason this workflow is safe. When `[@key]` sits inside a hand-written `[^fn]:` definition, citeproc renders the citation in place, inside that note. It does *not* mint a separate footnote.

```
[^fn1]: [@key1], ¶6.   →   [1] Wilhelmina Aldgate, The First Fictional Treatise (...)., ¶6.
[^fn3]: [@key2].        →   [3] Cassius Bromfield, "A Second Invented Study..." (...)
```

Consequence: the hand-written `[^fn1]/[^fn2]/[^fn3]` numbering is **preserved exactly as written**. There is no interleaving and no renumbering, because citeproc never creates competing notes. 

### 2.2. The one rule that keeps it safe: never leave a bare `[@key]` in body text

A bare citation in running text (not inside a footnote) under a notes style is exactly the case from the older `results.md`: citeproc generates its own footnote and seizes control of the entire numbering sequence, interleaving and renumbering the hand-written notes. So the single discipline to enforce is:

> Under a notes style, every `[@key]` must live inside a `[^fn]` footnote.

This is a good candidate for a BlobTxt lint/validation check (flag any `[@...]` that is not within a footnote definition).

### 2.3. Locators go *inside* the bracket, not after it

Putting the locator after the closed bracket:

```
[^fn1]: [@key1], ¶6.   →   ...Treatise (Imaginary University Press, 2019)., ¶6.
```

leaves `¶6` as dumb trailing text and produces a **stray doubled period** (`2019)., ¶6`). The locator is not part of the citation, so it is not integrated. The correct, pandoc-native form puts the locator inside:

```
[^fn1]: [@key1, ¶6].   →   Aldgate, The First Fictional Treatise, para. 6.
```

### 2.4. Citation syntax: `@key` is the token, brackets set the mode

`@key` is the thing resolved against the bibliography. The brackets and the comma do the rest:

| Form | Renders as | Use |
| --- | --- | --- |
| `@key1 argues...` | "Wilhelmina Aldgate argues..." (author lifted into prose) | in-text / narrative |
| `[@key1]` | parenthetical or note form | the normal footnote case |
| `[@key1, p. 6]` | citation + locator | locator inside the bracket |
| `[see @key1, ¶6, on it]` | prefix "see", locator, suffix "on it" | full form |
| `[@key1, p. 6; @key2, ch. 2]` | two citations in one note, `;`-separated | multiple sources |

The comma-locator is parsed in both bracketed and unbracketed forms. Brackets are what uniquely enable a prefix, a suffix, multiple citations, and clean fencing from surrounding note prose.

### 2.5. Use recognized locator labels (`p.`, not `pg.`)

Pandoc only normalizes locator labels it recognizes. Unrecognized labels are printed verbatim.

```
[@key1, pg. 12]    →   ..., pg. 12     (label kept literally — wrong)
[@key1, p. 12]     →   ..., 12         (Chicago drops "p." for a clean number)
[@key2, Chapter 5] →   ..., chap. 5    ("Chapter" recognized and normalized)
```

Recognized labels include `p.`/`pp.`, `chap.`/`Chapter`, `sec.`, `para.`/`¶`, `vol.`, `bk.`, `fig.`, etc. Prefer `p.`/`pp.` for pages.

### 2.6. `@` is the sole citation trigger, no collision with other syntax

A `[...]` is parsed as a citation only if it contains an `@`. Everything else coexists untouched in the same note:

```
[bracketed phrase]        →   stays literal "[bracketed phrase]"
![alt](img.png)           →   image
[link](http://x.com)      →   link
[^othernote]              →   footnote reference
```

So plain bracketed text inside footnotes is safe.

### 2.7. Repeat citations are stateful (carried over from results.md)

First occurrence of a key renders full; later occurrences auto-shorten (`Aldgate, The First Fictional Treatise`). A citation embedded mid-sentence in a note renders parenthesized; a citation that *is* the whole note does not. Both are correct CSL behavior, not bugs.

## 3. How to use Chicago notes with pandoc
### 3.1. Usage

For real use (not the test harness), the moving parts are: a bibliography file, a CSL style file, and the `--citeproc` flag.

**Bibliography file.** Export from Zotero (with Better BibTeX) as either CSL-JSON (`.json`) or BibTeX (`.bib`). Either works; CSL-JSON is closest to what citeproc uses internally.

**CSL style.** For Chicago footnotes use `chicago-notes-bibliography.csl` (full note + bibliography). The author-date variant (`chicago-author-date.csl`) is a *different* style that keeps citations inline as `(Author Year)` and generates no footnotes (the wrong one for this workflow). Both live in the CSL repo (github.com/citation-style-language/styles).

**Point the document at them.** Either via YAML frontmatter:

```yaml
---
bibliography: refs.json
csl: chicago-notes-bibliography.csl
---
```

or on the command line (command-line flags override frontmatter):

```bash
pandoc paper.md --citeproc --bibliography refs.json --csl chicago-notes-bibliography.csl -o paper.html
```

### 3.2. Bibliography page

`citeproc` looks for an element with `id="refs"` and injects the list there; if none exists it appends at the end.

To control placement, drop an empty **fenced div** with that id wherever you want the list. The heading above it is optional and its text/level are not parsed. Only the `id="refs"` matters:

```markdown
## Bibliography

::: {#refs}
:::
```

A bare `{#refs}` line does *not* work (renders literally), and putting `{#refs}` on the heading does *not* work (the div is what gets filled, not the heading). 

To just give the auto-appended list a title without placing it manually, set `reference-section-title: Bibliography` in the frontmatter. 

To drop the reference list entirely and keep only the footnotes, set `suppress-bibliography: true` in the frontmatter.

## 4. Artifacts

- `test-chicago.md` — citations inside footnotes (the main case).
- `test-locator.md` — inside- vs outside-bracket locator comparison.
- `test-chicago.html` — rendered output.
- `refs.json`, `chicago-notes-bibliography.csl` — shared with the first test.

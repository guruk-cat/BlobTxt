# Output

## Printing

Blobs can be printed or saved as PDF via the standard macOS print dialog. Users select a print profile in Settings (under Appearance); profiles control the full visual presentation — fonts, margins, heading styles, etc.

### Print Flow (`ProjectStore.printBlob`)

`printBlob(blobID:in:)` drives the full pipeline:

1. Generate HTML from blob's TipTap JSON using `loadBlobHTML()` (preserves headings, lists, bold/italic/underline, blockquotes, footnotes with two-way linking)
2. Load the active print profile CSS from `Resources/print-profiles/`
3. Wrap the HTML fragment in a minimal `<html>` document with the profile CSS injected
4. Create a temporary off-screen `WKWebView`, load the document, and invoke `printOperation(with:)` on macOS 13+
5. Show the system print sheet

`image` nodes render as `<figure><img src="..." alt="..."></figure>`. The `src` is a base64 data URL stored in the blob JSON. Print output respects `imageLimitHalfWidth` by injecting `--ft-print-img-max-width: 50%|100%` as a CSS variable before the profile CSS; profiles consume it via `figure { max-width: var(--ft-print-img-max-width, 100%) }`.

### Print Profiles

Print profiles are self-contained CSS files in `Resources/print-profiles/`. Each profile is named `<profileName>.css` and owns all styling: fonts, sizes, margins, headings, lists, blockquotes, footnotes, and figures. Selection is persisted via `@AppStorage("printProfile")` (defaults to the first available profile if not set).

To add a new profile: create a `.css` file in `BlobTxt/Resources/print-profiles/`, add it to the Xcode target's "Copy Bundle Resources" build phase, and restart the app. The profile appears in Settings automatically. All profiles should include `sup { line-height: 0 }` to prevent footnote superscripts from expanding line height.

### Footnote HTML

`ProjectStore.renderNodeHTML()` handles footnote-related TipTap node types for print HTML:

- `footnoteReference` → `<sup><a href="#fn:1" id="ref:1" class="footnote-ref" data-reference-number="1">[1]</a></sup>`
- `footnotes` / `footnote` → `<ol class="footnotes"><li id="fn:1">...content... <a href="#ref:1" class="footnote-backlink">↑</a></li></ol>`

Both elements also carry an optional `data-id` attribute when set by the TipTap node.

## DOCX Export

A blob open in the editor can be exported via **File → Export to Document** (disabled when no blob is open). A macOS Save panel appears with the blob's title pre-filled; the `.docx` is written to the chosen location. Footnotes in BlobTxt are rendered as endnotes in the app and in print, but as proper page footnotes in the exported `.docx`.

**File → Export to Document** is disabled whenever `ProjectStore.activeEditorBlobID` is `nil`. `FocusedValue` is not used here because the editor is a `WKWebView`, which breaks `FocusedValue` propagation when input focus moves to WebKit. The `@Published` property on the shared store instance is reliable regardless of focus.

### How It Works

`ProjectStore.exportBlobDocx(blobID:in:)` drives the pipeline:

1. Load blob's TipTap JSON from disk
2. Walk the node tree to produce OOXML XML strings (body paragraphs + footnote definitions), collecting hyperlink relationships via `DocxContext`
3. Write XML parts to a temp directory
4. Bundle into a `.docx` archive via `/usr/bin/zip`
5. Read the archive as `Data`, clean up the temp directory, return `(data: Data, suggestedName: String)`

`EditView` listens for the `.exportDocument` notification, calls `exportBlobDocx`, presents `NSSavePanel`, and writes the data to the chosen URL.

### OOXML Package Structure

A `.docx` is a ZIP archive of XML files per the ECMA-376 / ISO 29500 Open XML standard. The exported package:

```
[Content_Types].xml
_rels/.rels
word/document.xml
word/_rels/document.xml.rels
word/styles.xml
word/numbering.xml
word/footnotes.xml
```

### TipTap → OOXML Node Mapping

`docxBlock()` handles block-level nodes and returns `[String]` (one `<w:p>` per paragraph). `docxInline()` handles inline nodes and returns a `String` of runs.

| TipTap node | OOXML output |
| --- | --- |
| `paragraph` | `<w:p>` with `Normal` style |
| `paragraph` after a `blockquote` | `<w:p>` with `BodyTextContinuation` style |
| `paragraph` inside a list item | `<w:p>` with `ListBullet` or `ListNumber` style |
| `heading` (level 1–3) | `<w:p>` with `Heading1` / `Heading2` / `Heading3` style |
| `bulletList` | passes `listType: "bullet"` to children |
| `orderedList` | passes `listType: "ordered"` to children |
| `listItem` | passes list type through to its paragraph child |
| `blockquote` paragraph children | `<w:p>` with `BlockQuote` style |
| `footnotes` container | collected into `word/footnotes.xml`; emits nothing into the body |
| `text` (bold) | `<w:r><w:rPr><w:b/>…</w:rPr><w:t>…</w:t></w:r>` |
| `text` (italic) | `<w:rPr><w:i/></w:rPr>` |
| `text` (underline) | `<w:rPr><w:u w:val="single"/></w:rPr>` |
| `text` (strikethrough) | `<w:rPr><w:strike/></w:rPr>` |
| `text` (code) | `<w:rPr><w:rStyle w:val="InlineCode"/></w:rPr>` |
| `text` (link) | `<w:hyperlink r:id="rIdN">` wrapping the run; `Hyperlink` character style; relationship in `DocxContext` |
| `hardBreak` | `<w:r><w:br/></w:r>` |
| `footnoteReference` | `<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="N"/></w:r>` |
| `image` | skipped |

### Named Styles

Every formatting feature is expressed through a named style, never through direct inline properties. This ensures that if the user edits a style in Word or Pages and re-applies it, no formatting is lost.

Paragraph styles:

| Style ID | Name | Purpose |
| --- | --- | --- |
| `Normal` | Normal | Base style; default for unstyled paragraphs |
| `Heading1` | heading 1 | H1 — bold, 20pt, space before/after |
| `Heading2` | heading 2 | H2 — bold, 16pt |
| `Heading3` | heading 3 | H3 — bold italic, 14pt |
| `ListBullet` | List Bullet | Bullet list item; references numbering definition 1 |
| `ListNumber` | List Number | Numbered list item; references numbering definition 2 |
| `BlockQuote` | Block Quote | Based on Normal; 720 twip left+right indent, extra vertical spacing |
| `BodyTextContinuation` | Body Text Continuation | Based on Normal; `w:firstLine="0"` — keeps paragraphs after a blockquote flush left even if Normal uses first-line indent |
| `FootnoteText` | footnote text | Footnote body paragraphs; 10pt |

Character styles:

| Style ID | Name | Purpose |
| --- | --- | --- |
| `FootnoteReference` | footnote reference | Superscript; applied to `<w:footnoteRef/>` and `<w:footnoteReference/>` elements |
| `Hyperlink` | Hyperlink | Blue (`#0563C1`), underlined |
| `InlineCode` | Inline Code | Courier New font |

### Footnotes in OOXML

Footnotes require two coordinated parts. In `word/document.xml`, at the reference point:

```xml
<w:r>
  <w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr>
  <w:footnoteReference w:id="1"/>
</w:r>
```

In `word/footnotes.xml`, the footnote body:

```xml
<w:footnote w:type="normal" w:id="1">
  <w:p>
    <w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>
    <w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>
    <w:r><w:t xml:space="preserve"> footnote text here</w:t></w:r>
  </w:p>
</w:footnote>
```

`word/footnotes.xml` also includes the required separator entries (`w:id="-1"` and `w:id="0"`) that Word expects. The footnote ID in both places is the numeric portion of the TipTap `fn:N` attribute.

### DocxContext

`DocxContext` is a `final class` helper threaded through the recursive node walkers. It accumulates two things that can only be finalized after the full tree walk: `hyperlinks: [(id: String, url: String)]` (each unique URL gets a relationship ID, `rId4` and up; `rId1–3` are reserved for styles, footnotes, and numbering) and `footnoteXML: [String]` (rendered `<w:footnote>` strings). Both are consumed after the walk to generate `word/_rels/document.xml.rels` and `word/footnotes.xml`.

### ZIP Assembly

After all XML strings are written to a temp directory, the archive is assembled by spawning `/usr/bin/zip` via `Process()`:

```
/usr/bin/zip -r <output.docx> [Content_Types].xml _rels word
```

The process runs synchronously (`waitUntilExit()`). The resulting file is read back as `Data`, the temp directory is cleaned up, and the data is returned to `EditView`. No external dependencies are required.

# Step 2: ProjectStore Content Layer

Status: complete.

## 1. Scope

Only `ProjectStore.swift`, `EditView.swift`, and `BlobTxtApp.swift` changed. No model files changed. No view files changed beyond the export removal.

## 2. What Changed

### 2.1. `ProjectStore.swift` — content methods

All blob content methods were rewritten to read and write `.md` files instead of `.json` files.

**`loadBlobContent(blobID:in:)`**

Reads `<projectUUID>/<blobUUID>.md`. Before returning, strips the YAML front matter block (if any) using `splitFrontMatter(_:)` so the editor receives only the body Markdown.

**`saveBlobContent(_:blobID:in:)`**

Before writing, reads the existing `.md` file to extract any current front matter. Prepends that front matter to the new body and writes the combined string. If no file exists yet, writes the body only. Front matter is preserved verbatim; no parsing or interpretation occurs in this step.

**`loadBlobExcerpt(blobID:in:)`**

Replaces the JSON walk with line-by-line parsing:
- Title: first line matching `^#\s+(.+)`; falls back to `blob.title` metadata if set (that path is unchanged), then `nil`.
- Body: first non-empty, non-heading line up to 200 characters.
- `bodyAttributed`: plain `AttributedString` from the body string. Inline mark rendering in card previews is deferred to the sidebar refactor.

**`loadBlobPlainText(blobID:in:maxWords:)`**

Calls `stripMarkdownSyntax(_:)` on the body, splits on whitespace, returns the first `maxWords` words joined by spaces.

**`loadBlobWordCount(blobID:in:)`**

Strips front matter, then filters out footnote definition lines (`^\[\^[^\]]+\]:`), strips Markdown syntax from the remainder, and counts whitespace-delimited tokens.

**`loadBlobHeadings(blobID:in:)`**

Iterates lines and calls `parseMarkdownHeading(_:)` on each. Returns a `[BlobHeading]` with `level` and `text` fields populated from ATX heading syntax (`#{1,3} text`). The `BlobHeading` struct is unchanged.

**`loadBlobHTML(blobID:in:)`**

Replaces `renderNodeHTML(_:)` (the hand-rolled TipTap JSON walker) with a call to `MarkdownHTMLRenderer.render(_:)`. The output HTML structure is compatible with existing print profile CSS so no print profile changes are needed.

**`replaceAllInBlobs(blobIDs:in:find:replace:)`**

Replaces the recursive `replaceInNode` JSON walk with `String.replacingOccurrences(of:with:options:)` on the front-matter-stripped body. Writes back via `saveBlobContent` which re-prepends front matter. Known limitation (same as before): matches that straddle Markdown formatting characters (e.g., a word split by `**`) are not found.

### 2.2. `ProjectStore.swift` — deleted code

All of the following were removed:

- `exportBlobDocx` (the entire public method and its implementation)
- `DocxContext` class
- `docxBlock`, `docxInline`, `docxRPr`, `docxXMLEscape`, `docxFootnoteEntry` methods
- `docxContentTypesXML`, `docxRootRelsXML`, `docxDocumentRelsXML`, `docxDocumentXML`, `docxFootnotesXML`, `docxStylesXML`, `docxNumberingXML` methods
- `renderNodeHTML(_:)`
- `extractText(from:into:)`
- `buildAttributedBody(from:)` and `attributedStringFromNode(_:)`
- `replaceInNode(_:find:replace:)`

### 2.3. `ProjectStore.swift` — new private helpers

**`splitFrontMatter(_ content: String) -> (frontMatter: String, body: String)`**

Detects a `---` … `---` YAML block at the start of the file and returns the two parts separately. Returns `("", content)` when no front matter is present. Called by `loadBlobContent` and `saveBlobContent`.

**`parseMarkdownHeading(_ line: String) -> (level: Int, text: String)?`**

Matches `^(#{1,3})\s+(.+)`. Returns nil for non-heading lines. Called by `loadBlobExcerpt` and `loadBlobHeadings`.

**`stripMarkdownSyntax(_ text: String) -> String`**

Removes common Markdown syntax characters using a sequence of regex substitutions in this order: footnote definitions, inline footnote references, images, links (keeping anchor text), bold+italic markers, inline code, heading markers, blockquote markers. Called by `loadBlobPlainText` and `loadBlobWordCount`.

### 2.4. `ProjectStore.swift` — `MarkdownHTMLRenderer`

A pure-Swift private struct added after the `ProjectStore` class. No SPM dependencies required.

The renderer does a single-pass line scan:
- Blank lines and footnote definition lines are consumed without emitting HTML.
- Fenced code blocks (`` ``` ``), blockquotes (`>`), unordered lists (`-`, `*`, `+`), and ordered lists (`1.`, `2.`, …) are detected at the block level and wrapped in appropriate HTML elements.
- All other lines are wrapped in `<p>`.
- Headings (`#{1,6} text`) produce `<h1>`–`<h6>`.
- Horizontal rules (`---`, `***`, `___`) produce `<hr/>`.
- Inline spans are handled by `inlineHTML(_:)`, which applies: XML escaping, inline code, images, links, footnote references (→ `<sup id="ref:N"><a href="#fn:N">N</a></sup>`), bold+italic, bold, italic — in that order to prevent partial matches.
- Footnote definitions collected during the line scan are emitted at the end as `<ol class="footnotes">`, matching the structure that print profiles expect.

The `replaceRegex` utility applies all matches of a regex to the input string, calling a closure to build each replacement from capture groups. It adjusts string offsets after each replacement so earlier substitutions do not invalidate later match ranges.

### 2.5. `BlobTxtApp.swift`

- Removed the "Export to Document" `Button` and its `.disabled(store.activeEditorBlobID == nil)` modifier from the `CommandGroup(after: .saveItem)` block.
- Removed `static let exportDocument` from the `Notification.Name` extension.

### 2.6. `EditView.swift`

- Removed the `.onReceive(NotificationCenter.default.publisher(for: .exportDocument))` block (the `NSSavePanel` DOCX save flow).
- Removed the `import UniformTypeIdentifiers` statement (no longer referenced after the export block was removed).

## 3. What Is Not Changed

- All model files (`Blob.swift`, `Project.swift`, `BlobFolder.swift`, etc.) — unchanged.
- All view files except `EditView.swift` (one block removed) — unchanged.
- `EditorBridge.swift`, `WebEditorView.swift` — unchanged.
- The `BlobHeading`, `BlobExcerpt`, `SearchResult`, `SnippetMatch` structs — unchanged.
- `printBlob(blobID:in:)` — signature unchanged; now calls `loadBlobHTML` which uses `MarkdownHTMLRenderer` instead of `renderNodeHTML`.

## 4. Notes

**No `swift-markdown` SPM dependency.** The plans called for using `apple/swift-markdown`. Instead, `MarkdownHTMLRenderer` was implemented as a self-contained struct. This avoids requiring a manual Xcode package add before the build works. The `loadBlobHTML(blobID:in:)` interface is unchanged, so the renderer can be swapped for a `swift-markdown`-based implementation later without interface changes.

**Front matter is opaque at this stage.** `splitFrontMatter` and `saveBlobContent` treat the front matter block as an opaque string and preserve it verbatim. Parsing and editing YAML front matter fields (title, author, tags) is deferred to the sidebar refactor.

## 5. Verification Checklist

Run after the migration script (`refactor/migrate_blobs.py`) converts an existing project's `.json` blobs to `.md`:

1. Launch the app; open the migrated project.
2. Open a blob — verify the editor loads its Markdown content correctly.
3. Edit and save (⌘S) — verify the `.md` file on disk contains the updated Markdown with any pre-existing front matter preserved.
4. Verify "Export to Document" no longer appears in the File menu.
5. Test File → Print — verify the print sheet shows correctly rendered HTML (headings, lists, footnotes).
6. Test cross-blob search — verify results appear, snippet cards show correct context, replace-all modifies `.md` files correctly.
7. Test word count and headings outline in the sidebar panels.

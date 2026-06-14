# CodeMirror Editor Customizations

This is the detailed reference for everything built on top of CodeMirror 6 (CM6) in the BlobTxt editor, and how each piece mounts into the library.

The point is consistency: there is one entry point, one theming model, and one config flow, and new features should follow them rather than inventing parallel mechanisms. All of the editor's JavaScript lives in `editor-src/src/main.js`, bundled by Vite into `BlobTxt/Resources/editor.html`. The Swift side loads that HTML into a `WKWebView` and talks to it through a narrow bridge.

## 1. Architecture Overview
### 1.1. The two sides

The editor is split across a JavaScript layer and a Swift layer, with a deliberately narrow boundary between them.

The JavaScript layer owns everything internal to the editor: the document, syntax parsing, decorations, theming, search, and tooltips. It exposes a small object, `window.editorBridge`, and emits messages back to Swift.

The Swift layer (`EditorBridge.swift`, `EditorMonitor.swift`, `WebViewAdapter.swift`) owns the document lifecycle: which file is open, when to save, and user preferences. It never injects CSS or reaches into CM6 internals. It only calls the bridge methods and reacts to messages.

The rule of thumb: if a change concerns how the editor renders or behaves, it belongs in `main.js`; if it concerns which document is open or what the user's settings are, it belongs in Swift and is communicated as config.

### 1.2. The Swift to JS boundary

Communication is intentionally minimal and flows through two channels.

From Swift to JS, the `EditorBridge` calls methods on `window.editorBridge` via `evaluateJavaScript`. The important ones are `load()` (called once with the full document and initial config) and `updateConfig()` (called with a sparse patch whenever a single setting changes). There are also direct action methods like `toggleSearch()` and `arrangeFootnotes()`.

From JS to Swift, the `post()` helper sends a typed message through `window.webkit.messageHandlers.editorBridge`. Each message is an object with a `type` field, for example `editorReady`, `documentChanged`, `scrollPositionChanged`, `openURL`, and the search panel open/close notifications. The Swift `userContentController` switches on `type`.

This means new features that need Swift involvement add one message type and/or one bridge method, never a new transport mechanism.

### 1.3. The scroll container

`.cm-scroller`, CM6's own scroll element, is the scroll container (`overflow-y: auto`), wrapped by `#editor`, a plain `div` at `overflow: hidden` that clips it. This is CM6's native arrangement, so selection-follow autoscroll, `scrollIntoView`, and scroll-driven measurement all work without special handling.

The scrolling column is centered by putting the max-width (from `buildFontTheme`) and `margin: 0 auto` on `.cm-scroller` itself. One consequence: the empty margins beside that column belong to the non-scrolling `#editor`, so a wheel or trackpad gesture over them does not scroll.

Code that needs the live scroll position reads or drives `view.scrollDOM` (the `.cm-scroller`): the per-blob scroll-position bridge to Swift, the centered ("typewriter") autoscroll, and the ResizeObserver that bottom-pads `.cm-content` so the last lines can reach the vertical middle.

Do not make `#editor` scroll instead by giving `.cm-scroller` `overflow: visible`. CM6 picks a scroll container by `scrollHeight > clientHeight` and ignores `overflow`, so it would mis-target the non-scrolling `.cm-scroller` and silently break drag-select autoscroll and `scrollIntoView`. An earlier design did exactly that, to float a focus-mode wallpaper behind the document; removing focus mode let the editor return to the native arrangement.

## 2. The Mount Point: the Extension Array

CM6 has exactly one place where behavior is assembled: the `extensions` array passed to `EditorState.create()` inside the single `new EditorView({...})` call. This array is the entry point for every customization. There is one `EditorView` instance for the whole app, held in the module-level `view` constant.

The current extension array, in order, contains:

- `markdown({ extensions: [footnoteImageFix, plainBracketFix, GFM, footnoteDefFix, conspicuousMarkStyle, headingOnlyFold] })`: the language, with the three custom parser handlers, GitHub-Flavored Markdown, the `styleTags` override that re-tags conspicuous marks, and the heading-only fold restriction (see sections 4, 5.1, and 9).
- `syntaxHighlighting(highlightStyle)`: token colors and weights.
- `headingLineDecorations`: a `ViewPlugin` that adds line-level classes.
- `inlineMarkDecorations`: a `ViewPlugin` that adds sub-token marks for footnote references.
- `linkDecorations`: a `ViewPlugin` that marks clickable URL ranges with `cm-blob-link` for the Cmd+click affordance.
- `cmdKeyTracking`: a `ViewPlugin` that toggles a `cmd-held` class on the editor while the Meta key is down.
- `footnoteTipField` and `footnoteHover`: the footnote tooltip's state field and hover-detection plugin (see section 6).
- `history()`: undo/redo.
- `wordMilestones` and `wordCountGutter`: the word-count milestone gutter and its backing state field (see section 9.2).
- `foldGutter({ markerDOM })`: the heading-fold gutter (see section 9.1).
- `drawSelection({ cursorBlinkRate: 1200 })`: the drawn caret and selection (see section 8).
- `search({ top: true, createPanel: createSearchPanel })`: search wired to our custom panel.
- `keymap.of([...])`: the merged keymaps, including `foldKeymap`.
- `EditorView.lineWrapping`: soft wrapping.
- `editorBaseTheme`: the static theme (see section 3).
- `fontCompartment.of(...)`: the reconfigurable font theme (see sections 3 and 10).
- `EditorView.updateListener.of(...)`: posts document and search-state changes to Swift.
- `EditorView.domEventHandlers({...})`: the Cmd+click link handler.

When adding a feature, the new extension is appended here. Anything that needs to swap at runtime is wrapped in a `Compartment` (section 10) rather than rebuilt by recreating the view.

## 3. Theming Model

This is the part most prone to mistakes, so the model is described in full.

### 3.1. Three layers, one owner each

There are three places styling can live, and each owns a distinct category.

`editor-src/src/style.css` owns only the page skeleton: the `#editor` container and the `html`/`body` reset. It does not style any `.cm-*` element. CM6 injects its own base theme with two-class specificity, so plain single-class CSS in this file would lose to it; that is why CM styling does not live here.

`editorBaseTheme`, built with `EditorView.theme()`, owns all static `.cm-*` appearance: content color, line height, footnote mark colors, blockquote indent, the caret and selection, the tooltip, the search match highlights, and the custom search panel. `EditorView.theme()` goes through CM6's own style system and wins by mount order, which is why it can override the base theme reliably.

`fontCompartment` owns the styling that changes at runtime with user preferences: font family, font size, and the text column width. It is a theme too, but lives in a compartment so it can be reconfigured without rebuilding the editor.

### 3.2. Colors come from CSS variables

Token and surface colors are never hardcoded in the theme. They are CSS custom properties (`--text-body`, `--surface-raised`, `--meta-indication`, and so on) declared with placeholder defaults in `style.css` and overwritten at runtime. The theme rules reference `var(--name)`, and `applyConfigToDOM()` sets the real values via `document.documentElement.style.setProperty()` whenever Swift sends a `colors` patch. A few derived colors (the active search-match background, the `::selection` color) are computed from the palette in the same function.

This separation matters: the theme defines structure and which variable each element uses; the palette is data pushed from Swift.

### 3.3. The &light and &dark trap

CM6's base theme uses selectors like `&light .cm-selectionBackground` and `&dark .cm-cursor`. These placeholders are only valid inside `EditorView.baseTheme()`, which passes a scope map that resolves them. `EditorView.theme()` passes no scope map and throws `RangeError: Unsupported selector: &light` while building the style module. That throw happens during `new EditorView()`, so the entire editor fails to construct and renders blank.

To override a base rule that is written with `&light`/`&dark`, do not copy the placeholder. Instead replicate the rule's specificity with concrete selectors and rely on mount order to win. The selection background override is the worked example:

- The base unfocused rule `&light .cm-selectionBackground` is two classes, so `.cm-selectionBackground` (which CM6 expands to `.<themePrefix> .cm-selectionBackground`) ties it and wins by mounting later.
- The base focused rule `&light.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground` is five classes, so the override uses the explicit `&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground` to match it.

The general lesson: when overriding CM6 defaults, read the actual base-theme selector in the library source, match its specificity, and let `EditorView.theme()`'s later mount order break the tie. Do not guess, and do not reach for `!important`.

## 4. Custom Parser Extensions

There are two Lezer `parseInline` handlers and one block handler, all inserted via `markdown({ extensions: [...] })` with explicit ordering. Each addresses a shape GFM mis-tags as muted syntax when it should be plain text:

- `footnoteImageFix` (before Image): `![^label]` with no trailing `(url)` would fire the Image parser. The handler consumes the `!` as plain text so the following `[^label]` is parsed normally.
- `plainBracketFix` (before Link): a bare `[some text]` would emit a `Link` node and mute both brackets. The handler consumes the `[` as plain text. It leaves genuine syntax alone — `[^label]`, `[text](url)`, `[text][ref]` — and images never reach it.
- `footnoteDefFix` (replaces the LinkReference leaf parser): a one-word footnote definition `[^label]: word` would be read as a link-reference definition. The handler returns null for `[^…]:` lines so they fall through to a paragraph.

This is the model for any future syntax-level adjustment: a named handler with explicit `before`/`after` ordering and tight match conditions. It is also the only correct layer for these fixes — decorations and CSS fail because `HighlightStyle` spans are the inner DOM node and win specificity.

## 5. Syntax Highlighting and Decorations

There are three distinct mechanisms for visual styling of content, used at different granularities.

### 5.1. HighlightStyle for tokens

`highlightStyle`, defined with `HighlightStyle.define()` and mounted via `syntaxHighlighting()`, sets token-level color and weight by Lezer tag: headings, strong, emphasis, urls, footnote label names, and processing instructions. Heading font sizes are deliberately not set here, because headings now match body size and only retain bold weight.

Structural marks need two different treatments. Link and image brackets and parentheses should recede, while list bullets, emphasis delimiters, and blockquote chevrons should stand out. The markdown parser does not distinguish them: it tags every mark (`HeaderMark`, `QuoteMark`, `ListMark`, `LinkMark`, `EmphasisMark`, `CodeMark`) with the single `processingInstruction` tag, so coloring them differently is impossible at the `HighlightStyle` level alone. The split is made one level lower, by re-tagging the conspicuous node types. A custom tag `conspicuousMark` (from `Tag.define()`) is assigned to `ListMark`, `EmphasisMark`, and `QuoteMark` through a `styleTags` override, `conspicuousMarkStyle`, carried in the `markdown({ extensions })` array. It is placed last in that array so its tag assignment wins over the base parser's and GFM's. `HighlightStyle` then maps `processingInstruction` to `--text-muted` (brackets, parentheses, `#`, backticks) and `conspicuousMark` to `--meta-indication` (list bullets, emphasis delimiters, blockquote chevrons).

Re-tagging is the right tool whenever one shared parser tag covers nodes that need different visual treatments: give the nodes a custom `Tag` via a `styleTags` override, then style that tag, rather than reaching for decorations.

### 5.2. Line decorations for whole-line layout

`headingLineDecorations` is a `ViewPlugin` that walks the syntax tree over the visible ranges and attaches whole-line CSS classes (`cm-md-h1`, `cm-md-blockquote`, `cm-md-footnote-def`). It rebuilds on document and viewport changes. Use this pattern for anything that styles or lays out an entire line based on its node type. Footnote definition lines are detected by a per-line regex because they are not a distinct node type in the parser.

### 5.3. Inline mark decorations for sub-token styling

`inlineMarkDecorations` is a `ViewPlugin` that applies `Decoration.mark()` ranges for styling that `HighlightStyle` cannot express, specifically coloring the brackets and label of a footnote reference `[^label]` differently. References are found by scanning visible text with `fnRefRe` because the GFM parser has no footnote-reference node.

The division of labor is worth keeping consistent: tags to `HighlightStyle`, whole lines to a line-decoration `ViewPlugin`, sub-token spans to a mark-decoration `ViewPlugin`.

## 6. Footnotes

Footnotes have shared parsing utilities plus two features that build on them.

`collectFootnoteDefs()` parses an array of document lines into a map from label to definition content (absorbing indented continuation lines) and a set of line indices belonging to definitions. `lookupFootnoteDef()` flattens one label's definition to a string. `fnRefRe` and `fnDefRe` are the shared regexes for inline references and definition lines.

The hover tooltip shows a definition when the pointer rests on a reference. It is three parts. `footnoteTipAt()` resolves a hovered position to a `[^label]` on its line and returns a tooltip whose `create()` builds a plain `<div class="cm-footnote-tooltip">`. `footnoteTipField` is a `StateField` holding the current tooltip, fed to the `showTooltip` facet. `footnoteHover` is a `ViewPlugin` that watches the pointer, showing the tooltip after a short rest and hiding it the moment the pointer leaves the reference. The box is themed in `editorBaseTheme`.

It drives `showTooltip` directly rather than using CM6's `hoverTooltip()` helper so it can set `clip: false`. That was required when `#editor` was the scroll container (section 1.3); now that `.cm-scroller` scrolls natively it is no longer necessary, but it is harmless and left in place. Simplifying this to the stock `hoverTooltip()` helper would be a valid future cleanup.

`arrangeFootnotes()` (a `window.editorBridge` method, triggered from a Swift menu item) renumbers references in order of first appearance and consolidates all definitions at the bottom, dispatched as a single transaction that replaces the whole document. It is pure string manipulation around one `view.dispatch()`, which is the right shape for any document-rewriting command.

## 7. Custom Search Panel

The search panel is a fully custom DOM UI that reuses CM6's search state machine. It is mounted by passing `createPanel: createSearchPanel` to `search()`. The panel function returns an object with `dom`, `mount()`, `update()`, and `destroy()`.

The panel owns only its markup and event wiring. All behavior is delegated to the exported search commands (`findNext`, `findPrevious`, `replaceNext`, `replaceAll`), and the query is driven by dispatching `setSearchQuery.of(new SearchQuery({...}))`. The panel reads current state with `getSearchQuery()` and keeps its fields in sync in `update()`, skipping any field the user is actively typing in. The find input is tagged `main-field="true"` so CM6 focuses it on open. Match highlighting is a function of the search state, not the panel, so it works automatically.

This is the template for replacing any CM6 built-in UI: supply the DOM through the extension's panel hook, and call the library's exported commands and state effects rather than reimplementing the logic.

## 8. Caret and Selection

By default the editor used WebKit's native caret, which cannot be restyled and blinks with an OS-level fade. To control the caret, `drawSelection()` is added to the extension array, which replaces the native caret and selection with CM6's own drawn `.cm-cursor` and `.cm-selectionBackground` elements.

Enabling `drawSelection()` has two consequences that the theme accounts for. First, it hides the native caret and forces native `::selection` transparent via a `Prec.highest` rule, so the caret color is set on `.cm-cursor` and the selection color is set on `.cm-selectionBackground` (see section 3.3) rather than through `caret-color`/`::selection`. Second, its default blink is already a hard on/off with no fade, because CM6 animates it with `steps(1)` keyframes; the rate is configured through `drawSelection({ cursorBlinkRate })` in milliseconds.

The caret is sized by a `transform: scaleY()` on `.cm-cursor`, which extends it symmetrically about its vertical center so it frames the glyphs with equal space above and below. The scale factor and the blink rate are the two tuning knobs, both currently hardcoded.

## 9. Gutters

There are two gutter columns to the left of the text, both rendered by CM6 inside `.cm-scroller`: the word-count milestone gutter (leftmost) and the heading-fold gutter (nearest the text). They share the gutter mechanism and are styled together in `editorBaseTheme` next to the `.cm-gutters` rules.

Their horizontal placement is not set explicitly. `.cm-scroller` is a centered, max-width column (`margin: 0 auto`), and CM6 lays the gutters out at its left edge with the text immediately to their right. So the gutters ride just left of the centered text, with no positioning CSS of our own.

### 9.1. Heading Fold

Heading sections are collapsible via a gutter indicator on each heading line.

`@codemirror/lang-markdown`'s `markdown()` extension includes a `foldService` for heading sections as part of its language support. It defines a fold range for each heading that spans from the end of the heading line to the end of the last line before the next heading of equal or higher level. Because this service is already registered by the language, `foldGutter` picks it up automatically with no additional fold-range code needed here.

The language separately attaches a fold range (via `foldNodeProp`) to every multi-line block node, which would also make blockquotes, ordinary multi-line paragraphs, and fenced code foldable, showing a marker on their first line. The `headingOnlyFold` config in the `markdown` extensions array overrides `foldNodeProp` for every `Block` node with a fold function that returns `null`, removing those ranges so only heading sections fold. Heading folding is unaffected because it comes from the `foldService`, not `foldNodeProp`.

`foldGutter({ markerDOM })` from `@codemirror/language` renders a gutter column to the left of the text. The `markerDOM` callback receives a boolean indicating whether the section at that line is currently open or collapsed, and returns a `<span>` element. Open-section markers use class `ft-fold-open` (▾) and collapsed markers use `ft-fold-closed` (›). `foldGutter` also bundles `codeFolding()` internally, which provides the fold state field.

The visibility of open markers is controlled by opacity in `editorBaseTheme`: `ft-fold-open` rests at `0.3` (dim but present) and rises to `1` on `:hover` of its gutter element, so the indicator is unobtrusive until the mouse is nearby. `ft-fold-closed` rises to `1` on hover the same way.

CM6 inserts a `[…]` inline widget after every folded range by default. This is suppressed with `.cm-foldPlaceholder { display: none }` in `editorBaseTheme`. The gutter indicator already signals a fold; the inline widget is redundant.

`foldKeymap` is merged into the keymap alongside the existing maps. The gutter's default `domEventHandlers` handle click-to-fold/unfold.

### 9.2. Word-Count Milestones

This gutter marks each line where the running word count first crosses a multiple of 100, so the margin reads 100, 200, 300 downward. It is entirely JS-side, since word count is a pure function of the document text. A `word` is a run of letters or digits with internal apostrophes or hyphens (`wordRe`), so bare markdown punctuation is not counted; there is no other special-casing.

`wordMilestones` is a `StateField` mapping each line to its milestone (or `0`), recomputed only on `docChanged` so scrolling never re-counts. A line shows the highest hundred it crosses, since only one marker fits per line.

The one subtlety is vertical alignment. Because `.cm-content` has `line-height: 2` and a gutter marker is top-aligned to the line block, the number would otherwise float into the leading above the text. The gutter element's line box is matched to one body text row (`line-height: font size × 2`) to center it; that value tracks the configurable font size, so it lives in `buildFontTheme`.

## 10. Configuration Flow

User settings reach the editor through one consistent path, and the editor never recreates itself to apply them.

`load({ content, scrollTop, config })` is called once after `editorReady` with the full document and the complete initial config. It replaces the document in a single dispatch (with history disabled and `suppressDocChanged` set so it is not reported as a user edit), restores scroll position, and applies the config.

`updateConfig(patch)` is called for every later change with a sparse object containing only the changed keys.

Both funnel into the same two helpers. `buildCompartmentEffects()` inspects the keys and produces `Compartment.reconfigure()` effects for anything that is a CM6 extension; today only the font compartment, which is rebuilt from the mirrored `currentFontSize`/`currentFontFamily` so a partial patch still has both values. `applyConfigToDOM()` handles everything that lives outside CM6's extension system: the autoscroll mode, the injected `::selection` style element, and the color variables.

The pattern for a new runtime-adjustable setting: if it is a CM6 extension, give it a `Compartment`, build its effect in `buildCompartmentEffects()`, and reconfigure it; if it is plain DOM or CSS, apply it in `applyConfigToDOM()`. Either way the key travels in the same config patch from Swift, and the view is never torn down.

## 11. Conventions Summary

For consistency in future work, the established patterns are:

- There is one `EditorView`. Mount features by appending to its extension array, never by recreating the view.
- Style `.cm-*` elements in `editorBaseTheme` (static) or a compartment theme (runtime). Keep `style.css` to page skeleton only. Use `var(--name)` for all colors.
- When overriding a CM6 default, read the base-theme selector in the library source and match its specificity; let mount order win. Never use `&light`/`&dark` in `EditorView.theme()`, and avoid `!important`.
- Syntax fixes belong in Lezer parser handlers; token styling in `HighlightStyle`; line layout and sub-token spans in `ViewPlugin` decorations. When one parser tag covers nodes that need different colors, re-tag the nodes with a custom `Tag` via a `styleTags` override rather than reaching for decorations.
- Reuse the library's exported commands and state effects when replacing built-in UI; supply only DOM.
- Settings flow from Swift as a config patch and are applied through `buildCompartmentEffects()` or `applyConfigToDOM()`. New Swift-facing actions add one `window.editorBridge` method and/or one `post()` message type.

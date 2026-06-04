# BlobTxt Docs

## Documentation Files

| File | What it covers |
| --- | --- |
| `docs-map.md` | This file. Index and "Where to Look" reference. |
| `data-model.md` | Data structs, `ProjectStore`, `AppColors`, follow macOS appearance. |
| `ui.md` | Editor (EditView, WebEditorView, EditorBridge, editor-src, FocusCustomizationView, LinkDialogView) and sidebar (FileNavigatorView, BlobOutlineView, BlobSearchView, BlobMetadataView, FloatingIslandView). |
| `output.md` | Print flow, print profiles, DOCX export (OOXML structure, node mapping, named styles, footnote wiring). |
| `colors.md` | Color palette design spec: hue tiers, color role mappings, contrast guidelines. |
| `dashboard.md` | Legacy reference for the retired dashboard. No longer reflects active code. |

## Where to Look

| Task | File(s) |
| --- | --- |
| Persistence, CRUD, sort order, drag logic | `ProjectStore.swift` |
| Blob outline heading extraction | `ProjectStore.loadBlobHeadings()`, `ProjectStore.BlobHeading` |
| Outline ↔ editor scroll sync | `EditorBridge.swift` (`scrollToOutlineHeading`, `activeHeadingChanged` notifications) |
| Sidebar panel switching | `SidebarView.swift`, `FloatingIslandView.swift` |
| Blob metadata (title, author, word count, last modified) | `BlobMetadataView.swift`, `ProjectStore.updateBlobMetadata()`, `ProjectStore.loadBlobWordCount()` |
| Cross-blob search, snippet extraction, replace-all | `ProjectStore.searchBlobs()`, `ProjectStore.searchSnippets()`, `ProjectStore.replaceAllInBlobs()` |
| Search ↔ editor highlight/scroll sync | `EditorBridge.swift` (`searchAndHighlight`, `scrollToSearchResult`, `clearSearchHighlights`, `reloadEditorContent`); `main.js` (`SearchHighlightExtension`) |
| Footnote HTML rendering | `ProjectStore.renderNodeHTML()` (cases: `footnoteReference`, `footnotes`, `footnote`) |
| JS ↔ Swift editor messages | `EditorBridge.swift`, `WebEditorView.toolbarInitJS` |
| Editor DOM / TipTap internals | `editor-src/src/main.js`, `editor-src/src/style.css` |
| Compiled editor (read-only) | `Resources/editor.html` |
| Settings and user preferences | `SettingsView.swift` |
| Color palette logic and theming | `AppColors.swift`, `Resources/colors.json` |
| Follow macOS appearance | `AppColors.applySystemAppearance(dark:)`, `ContentView.onChange(of: systemColorScheme)` |

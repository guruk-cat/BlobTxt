# Merge Blobs

## 1. Purpose

This document is a map of the Merge Blobs panel, not a manual: it points to where things live, and the code carries the detailed explanations in comments. For how the panel fits into the whole app, see `codebase-map.md`.

Merge Blobs is a window-level wizard that combines several blobs into one new blob. It walks three stages (select the blobs and their order, adjust their headings, then name the result and give it metadata) and writes a new file at the project root.

## 2. Where the panel lives

Merge Blobs is launched from the File Operations sidebar panel and hosted as an overlay over the whole window.

- `Views/Sidebar/FileOpsPanelView.swift` is the File Operations panel. Its "Merge Blobs" button posts the `.openMergeBlobs` notification.
- `App/BlobTxtApp.swift` defines the `.openMergeBlobs` notification name (alongside the rest).
- `Views/ContentView.swift` hosts the panel. It listens for `.openMergeBlobs` (closing the sidebar and raising the overlay), and owns the two exits: `cancelMergeBlobs` returns to the File Ops panel, `finishMergeBlobs` reopens the sidebar at the navigator and opens the freshly created blob. The new file appears in the navigator on its own, because the sidebar's `FileSystemWatcher` sees the write at the project root.
- `Views/FileOps/MergeBlobsPanel.swift` is the shell: the scrim, the single split rounded-rectangle, the stage routing, the footer navigation (Cancel/Back and Continue/Finish), and the final file write in `finalize()`.

## 3. The stages

Each stage is its own view, switched on by `MergeBlobsPanel.stageBody`. Selection and headings use the left/right split (left `chromePanel`, right `surface`); the metadata stage fills the whole panel with `chromePanel`.

### 3.1. Selection

`Views/FileOps/MergeSelectionStage.swift`. Left pane: a read-only navigator (its own `NavigatorModel`, folders and `.md` blobs only, nothing editable). Right pane: the drop zone, a numbered ordered list of the chosen blobs. Drag-and-drop reuses the navigator's manual mechanism — a single `DragGesture` in one shared coordinate space (`mbSpace`) with row and zone frames tracked through preferences — to add a blob, reorder one, or drag one out to remove it. Continue requires at least two blobs.

### 3.2. Headings

`Views/FileOps/MergeHeadingsStage.swift`. Left pane: the adjustment controls, a merge-wide card on top (adjust all, renumber, number H1) and one card per blob (its highest heading level, a per-blob level adjustment, or an "add a heading" affordance when the blob has none). The level adjustment is a signed integer: positive promotes (toward H1), negative demotes (toward H6). Right pane: a live preview of every heading the merge will produce, styled roughly like the editor. The preview is exactly `MergeEngine.merge(...).headings`, so what is shown is what gets written. Blob bodies are read once on appear and cached; only the config changes here. The custom `StepperControl` and `ToggleRow` controls are at the bottom of this file.

### 3.3. Metadata

`Views/FileOps/MergeMetadataStage.swift`. Split like the earlier stages: the fields fill the `chromePanel` left pane (grown to half the panel), leaving the `surface` right pane empty. The fields are a required file name (created at the project root as `<name>.md`) plus optional front-matter metadata (title, authors, date, institutions), styled like the Metadata panel. Every edit is mirrored into the session so the Finish button — which lives in the panel footer and reads name and metadata back from the session — always sees the current values, and so entries survive stepping back to earlier stages.

## 4. The merge engine

`Views/FileOps/MergeEngine.swift` is the transform, kept apart from the UI so the preview and the file write share one code path and cannot drift. `merge(session:body:)` returns both the file body and the heading list; callers pass a `body` closure that is cached text for the preview and a fresh disk read for finalizing.

The pipeline:

1. Per blob: prepend a synthesized heading if asked, then level-adjust and clean every heading line (`level − (adjustBy + adjustAllBy)`, clamped to 1...6, manual numbers stripped), keeping non-heading and fenced-code lines verbatim. A heading is stored as `(level, bare text)`; the level is the single source of truth, and numbers are reapplied only by step 3.
2. Footnotes: renumber across the merge so every reference is unique (see section 5).
3. Across the whole document: collect the final heading list and, when renumbering is on, prepend continuous nested numbers (anchored at H2, or H1 when "Number H1" is set).

`MergedHeading` (a heading's level and text) is defined here.

## 5. Footnotes

`MergeEngine.renumberFootnotes` ports the editor's "Arrange Footnotes" command (`main.js`, invoked elsewhere through `EditorBridge.arrangeFootnotes`) so it can run on blobs read from disk rather than the open editor. The same regex shapes are used: a reference `[^label]`, a definition line `[^label]: text`, and its indented continuations.

The merge version is blob-aware, which is the point: each blob numbers its references independently, so a reference resolves only to its own blob's definitions, and the numbers are then assigned in one continuous sequence in document order. Every definition is collected at the foot of the merged file. This Swift port and the JS command are two copies of one algorithm; a change to the footnote rules in either needs the same change in the other.

## 6. Session state

`Views/FileOps/MergeSession.swift` is the flow's shared state, owned by `MergeBlobsPanel` so it survives stage changes: the ordered selection, the per-blob and merge-wide heading config (`BlobHeadingConfig`, `MergeWideHeadingConfig`, both defined here), the file name, and the metadata. The selection-stage navigator is a separate `NavigatorModel`, also owned by the panel.

## 7. File creation

`Services/ProjectStore.createBlob(named:metadata:body:in:)` writes the merged blob: it appends `.md`, de-duplicates the name against the directory, and serializes the metadata to YAML front matter ahead of the body using the same serializer as a normal save. `finalize()` calls it with the project root as the directory.

## 8. Common starting points

- Change the merge transform (level adjustment, numbering, separators): `MergeEngine.merge`.
- Change footnote handling: `MergeEngine.renumberFootnotes`; keep it in sync with `arrangeFootnotes` in `main.js`.
- Add or change a heading adjustment control: the cards in `MergeHeadingsStage`, backed by a field on `BlobHeadingConfig`/`MergeWideHeadingConfig` in `MergeSession`.
- Change what the new file is named or where it lands: `MergeBlobsPanel.finalize` and `ProjectStore.createBlob(named:metadata:body:in:)`.
- Change the launch or exit flow: `FileOpsPanelView` (launch), and the `.openMergeBlobs` handler plus `cancelMergeBlobs`/`finishMergeBlobs` in `ContentView`.

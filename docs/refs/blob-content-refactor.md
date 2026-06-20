# BlobContent I/O Refactor Plan

## 1. Motivation

Today there is no in-memory document model. Each editor surface (the main window and the mini view) reads its file from disk on mount and writes it back on save, independently. "One source of truth" is enforced socially, by the one-place-per-blob gate, rather than structurally.

This produces a whole class of bugs rather than isolated ones. The mini-view staleness bug (a surface reusing its mounted state and never re-reading disk) was one instance; any place where a view's lifecycle and a disk read fall out of sync is another. It also means two surfaces on the same blob would race to write, with the last writer silently winning.

The refactor introduces a per-blob in-memory owner that is the single source of truth for content and the single writer to disk. Surfaces bind to it instead of touching disk directly.

## 2. Target Model

### 2.1. BlobContent

A reference type (`ObservableObject`) in `Sources/Models/`, one instance per open blob, keyed by symlink-resolved path (the navigator's identity rule). It owns:

- `body`: the canonical content with front matter stripped.
- `metadata`: the parsed front matter, replacing `ProjectStore`'s single shared `activeMetadata` slot.
- `isDirty`: whether the in-memory content differs from disk. This is the only dirty flag that matters for persistence.
- `revision`: bumped on every committed change, so a surface can tell it is showing stale content.

It absorbs the front-matter merge, serialization, and disk write currently spread across `ProjectStore` (`saveBlobContent`, `updateActiveMetadata`, the front-matter helpers). It is the single writer for its blob.

`Blob` (the existing value struct: URL plus display name) is unchanged and unrelated. It is a passive handle; `BlobContent` is the live owner.

### 2.2. LifecycleStore

A dedicated service holding the registry of open documents, `[ResolvedPath: BlobContent]`.

- `content(for:)` returns the existing `BlobContent` or creates one by reading disk once.
- Reference-counted: a surface attaches on mount and detaches on unmount. When the last surface detaches, the document is flushed to disk and then evicted (always flush-then-evict; no background unsaved buffers).
- Project close and delete flush-or-discard, then drop.

It also holds the session scroll cache (see 2.4).

### 2.3. Surfaces (EditorMonitor)

Surfaces stop reading and writing disk directly.

- The `readBody` versus `loadBlobContent` split disappears. Both surfaces load from `BlobContent.body`, so a freshly mounted surface always shows the latest in-memory content, even before any disk write.
- The surface still observes CodeMirror's `docChanged` and runs the debounce, because it is the only place edits are visible. On fire it commits its content to the `BlobContent`, and the document performs the save. The surface captures content; the owner persists it.
- Reconciliation is safe-not-live, with two points:
  - On blur, file switch, or close, the surface commits to the document.
  - On becoming key, if the document's `revision` differs from the revision the surface loaded and the surface has no local edits, it reloads from `BlobContent.body`.

Because macOS keeps only one window key at a time and editing requires focus, the window in which two surfaces diverge without a focus change is small. The accepted fallback: if a surface is dirty and the document changed underneath it, the next commit wins (last-writer). This is the documented cost of "not live."

### 2.4. Scroll position

Scroll stays session-scoped and per-blob, exactly as today, but the cache moves from `ProjectStore.blobScrollPositions` into `LifecycleStore`. It is deliberately not part of `BlobContent`: scroll is view state, not content, and folding it in would make two surfaces on one blob fight over a single shared value. (Making scroll genuinely per-surface is a possible later follow-up, orthogonal to this refactor.)

### 2.5. Metadata panel

The Metadata panel binds to the active document's `BlobContent.metadata` instead of `ProjectStore.activeMetadata`. The shared-slot workaround that made the mini view use `readBody` goes away, since there is no single shared slot anymore.

## 3. Phasing

Each phase should build and be verified before the next.

1. Introduce `BlobContent` and `LifecycleStore`; migrate `ProjectStore`'s blob I/O into them. Main and mini both route through the registry. No behavior change yet; the gate stays in place.
2. Move dirty-tracking and saves into `BlobContent`. Verify debounced autosave, flush-before-switch, and save-on-close still behave.
3. Remove the one-place-per-blob gate and add focus reconciliation. The same blob in main and mini is now safe.
4. (Separate, later) Multiple mini views: the singleton `Window(id:)` scene becomes a value-based `WindowGroup` keyed by document identity. This is a windowing change layered on top of the now-safe I/O, not part of it.

## 4. Out of Scope

- Live, keystroke-by-keystroke shared editing between surfaces (two CodeMirror views sharing one document). The model here is safe-not-live.
- Persisting scroll or open-document state across app launches.
- Handling external on-disk edits while a blob is open.

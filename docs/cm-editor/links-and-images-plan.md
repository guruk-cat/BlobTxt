# Links and Images Plan

This is a brief plan for three related features: a visual indication for Cmd+click links, support for local file and heading links with autocomplete, and image support including a hover preview. It records decisions and the intended architecture, not implementation detail.

## 1. Cmd+Click Indication

Cmd+click already works: `domEventHandlers.click` in `main.js` resolves the click position to a `URL` node and posts `openURL`, which Swift opens via `NSWorkspace`. Only the visual affordance is missing.

The indication is split so the pointer never drives decoration recomputation.

- A `ViewPlugin` statically marks every clickable URL range with a class (`cm-blob-link`), rebuilt only on document and viewport changes, in the manner of `headingLineDecorations`.
- A `cmd-held` class on the editor container reflects the Meta key state. It is derived primarily from `event.metaKey` on `mousemove`, with `keydown`/`keyup` and a window blur handler as backups, because macOS `keyup` for Cmd is unreliable.
- The color change is pure CSS in `editorBaseTheme`: `.cmd-held .cm-blob-link:hover` switches the link from `--text-muted` to `--meta-indication`, with a pointer cursor.

The highlight covers the same range the click handler acts on (the `URL` node), so the affordance does not imply more is clickable than is.

This `cm-blob-link` plugin is the shared foundation for the local links below.

## 2. Local File and Heading Links

### 2.1. Classification and routing

JavaScript classifies each link into three kinds and routes accordingly.

- External (`http`, `https`, `mailto`, and similar): unchanged, posts `openURL`.
- Same-file fragment (`#heading`): handled entirely in JavaScript by scrolling to the heading found in the syntax tree. No Swift round-trip.
- Local file (`./other.md`, `images/x.png`, optionally `other.md#heading`): posts a new `openBlob` message with the raw href. Swift resolves the path relative to the currently open file's URL and reuses the existing blob-open flow.

Paths resolve relative to the current file.

Update during implementation: A cross-file anchors (`other.md#heading`) are not implemented because the editor's rememberance of the blob's last scrolled location should (and does) win.

### 2.2. Heading slugs

Link resolution and autocomplete must agree on how a heading maps to an anchor, so a single slug function (GitHub-style: lowercase, spaces to hyphens, punctuation stripped) is defined once and shared by both.

## 3. Autocomplete

Autocomplete uses `@codemirror/autocomplete` with a completion source that fires inside link syntax.

Completing file paths requires the project's file list, which only Swift has. The list is pushed to JavaScript through the existing config flow and refreshed on the FSEvents changes the navigator already watches.

Same-file heading completion (after `#`) comes from the syntax tree and is included. Cross-file heading completion requires reading other files and is deferred to a later pass.

## 4. Navigator Changes

The navigator currently lists only `.md` files and strips extensions. The new behavior follows three decisions.

- It lists every file except OS-hidden ones. The rule is to skip names with a leading dot, which also hides `.git`, `.blaze`, and the `.blobtxt` marker.
- It shows full filenames including extensions, for blobs and other files alike.
- Opening a row branches by type: `.md` opens in the editor, an image opens in a native viewer (section 5), and any other type is handed to the OS via `NSWorkspace.open`.

Showing extensions makes the rename flow extension-agnostic. Rename must edit the whole filename, including the extension, rather than stripping and re-appending `.md`, so that renaming a non-blob file does not corrupt its extension.

## 5. Images

Images are not rendered inline in the document body. A blob keeps the raw `![alt](path)` markdown, and the image is shown in two other places.

### 5.1. Image as the active document

When an image file is opened from the navigator, the content region shows a native SwiftUI image viewer instead of the web view, selected by file type. This keeps non-editor UI in Swift and avoids a second JavaScript environment.

### 5.2. Hover preview

Hovering an image link in a blob shows a tooltip containing the image, built with `hoverTooltip()` on the same template as the footnote tooltip.

### 5.3. Serving image bytes

Both the viewer and the tooltip need the image bytes. The existing `WallpaperSchemeHandler`, which already serves a local file over the `blobtxt://` scheme, is generalized into a project-image scheme handler (for example `blobtxt-img://<relative-path>`). This streams large files and respects the sandbox without base64 data-URL bloat.

## 6. Build Order

The link-marking plugin and the local-link classification underpin the rest, so the natural order is: Cmd+click indication, local link routing, navigator and image-viewer changes, the image scheme handler, then autocomplete.

# Refactor Phase 2

## 1. Overview of Phase 1
### 1.1. Codebase Affected



### 1.2. New Architecture

A **project** is a directory on disk. A `.blobtxt` file marks it as a BlobTxt project and holds minimal project-level config. A **blob** is a `.md` file. Its path is its identity, not a UUID like in the present app architecture. A **folder** is a real OS subdirectory. BlobTxt's navigator reflects the file system; it doesn't own the structure. This eliminates: UUID-based blob identifiers, `project.json` as a structural index, virtual folder management, sort order tracking, and the bulk of ProjectStore's current CRUD logic.

## 2. Scope for the Incoming Pass

In this session, necessary changes in `ProjectStore.swift` will be implemented to prepare for the migration from TipTap to Markdown. More specifically, these will be content extraction services in ProjectStore.

### 2.1. Methods

| Method | Change |
| --- | --- |
| `loadBlobContent` | Reads `.md` file; strips YAML front matter before returning content to editor |
| `saveBlobContent` | Writes `.md` file; re-prepends existing front matter before writing |
| `loadBlobPlainText` | Strip Markdown syntax characters from raw text |
| `loadBlobHeadings` | Regex over lines: `^(#{1,3})\s+(.+)` |
| `loadBlobExcerpt` | First `# ` line as title; first paragraph as body |
| `loadBlobWordCount` | Strip syntax, split on whitespace |
| `loadBlobHTML` | Markdown → HTML via a Swift Markdown parser (see below) |
| `replaceAllInBlobs` | String replacement on raw Markdown (see below) |

### 2.2. Swift Markdown Parser

`loadBlobHTML` is used by print and needs a proper AST-based conversion, especially for footnotes. Apple's `swift-markdown` package (open source, SPM-compatible, CommonMark compliant) handles this. A custom visitor handles footnote nodes. The footnote-related code is tangled with the editor. Hence, for the footnotes, a skeletal work that will later be filled in, when the editor refactor is undertaken, is acceptable for now. Have it documented clearly.

### 2.3. Replacing All Service

Naive string replacement on the raw Markdown text is acceptable for the initial implementation. The edge case where a search term straddles a formatting boundary (e.g., "hello world" where "hello" is bold and " world" is not) is rare and can be documented as a known limitation.

### 2.4. Front Matter Handling

Blob files, which are now expected to be `.md` files, will come with a YAML-style frontmatter. `loadBlobContent` and `saveBlobContent` become the front matter gatekeepers. On load: detect and strip the `---` front matter block before passing content to the editor. On save: detect existing front matter in the stored file, preserve it, and write the new content body after it. The editor never sees or touches front matter — that is entirely the metadata panel's domain, addressed in the sidebar refactor.

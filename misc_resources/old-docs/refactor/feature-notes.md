# Notes for Feature Rebuilds

The following are some things to remember while rebuilding some of the old features after the refactor.

## 1. File Handling
### 1.1. Blob Metadata

Blob files may come with a YAML front matter. Reading and writing this front matter has been deferred. ProjectStore passes to the editor the Blob contents excluding the front matter:

- On load: if the file starts with `---`, the front matter block (up to and including the closing `---` line) is stripped before the body is returned to the editor.
- On save: the existing file is read first to detect any front matter. If found, it is preserved and written before the new body.

It is designed this way such that a dedicated UI element (such as a sidebar panel) will be the point of access for the metadata.

### 1.2. File Watching

Because project structure is now the live file system, changes made outside BlobTxt (Finder, Terminal, other apps) need to be reflected in the navigator. `FSEventStream` watching is not set up; the list refreshes only on appear and when `selectedProjectID` changes.

### 1.3. File Naming

Each blob is a `.md` file anywhere within the project directory tree (including in subdirectories). The file path is the blob's identity. Currently, a newly created blob gets the filename `untitled.md`. Not yet implemented is a filename derivation logic:

- On first save, the app derives a name from the content: first heading if present, otherwise the first line of text, slugified to a valid filename. This is the current behavior in the app, with `ProjectStore` having the services necessary for this action.
- If the derived name is already taken in the same directory, a numeric suffix is appended (`extended-mind-2.md`)
- Subsequent frontmatter title changes do not rename the file. The filename is set once on first save and thereafter stable unless the user explicitly renames it in the navigator (or elsewhere, like Finder or Terminal).

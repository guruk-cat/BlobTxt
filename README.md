# BlobTxt

## 1. About
### 1.1. What is BlobTxt?

BlobTxt is a text editor. It is a hybrid design that combines the roles of a notetaking app and those of a conventional document editor. It is intended to support two distinct kinds of work in a single environment:

1. Rapid brainstorming, piece-wise drafting, and jumping between ideas
2. Careful organization of drafts, and longer sessions of focused writing.

This is done through a combination of three things. **First, the Markdown format.** With enough extensions, it's a powerful tool that can functionally replace the DOCX format for most people who do writing-intensive work. With support for CSS-aided printing and file exports, the capabilities become even larger. **Secondly, git integration.** Git-based version control is industry standard for developers and computer scientists for a reason. Moreover, git is not a solution; it is a set of tools. And if a hacksaw works just as well for cutting canvas at an artist's shop as it does for cutting metal at the hardware store, it works. **Thirdly, integration with a custom pipelining tool.** Sometimes, a writer or researcher wants to track, not the *version history* of a file in the software sense, but its *development stage*, where a piece is understood to be in a lifecycle (e.g., loose note, trying an idea, active draft, or settled). Git is not great for this kind of tracking. So, I began to build a tool just for this purpose: [blaze](https://github.com/guruk-cat/blaze), named after the bygone practice of trailblazing.

### 1.2. Authors and Credits

The app was designed by June Jung. The codebase was vibe-coded with Claude by Anthropic.

The actual text editor portion of the app is built on [CodeMirror 6](https://codemirror.net). The editor is wrapped inside the app through Apple's `WKWebView` library.

### 1.3. Versions

BlobTxt is currently undergoing a major refactor. 

For the older version, a macOS `.app` file that has been compressed into a `.zip` is available in the `distro/` folder. Project files will be stored in `~/Documents/BlobTxt/`, and user settings are stored through `@AppStorage`.

## 2. Screenshots

**Editor and sidebar** (shown in the default `paper` color palette):
![editor1](./misc_resources/imgs/editor1.png)

**Editor without sidebar** (shown in an alternative `stone` color palette):
![dashboard](./misc_resources/imgs/editor2.png)

**Focus mode in fullscreen:**
![focus-mode](./misc_resources/imgs/focus-mode.png)

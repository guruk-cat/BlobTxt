# BlobTxt

## 1. About
### 1.1. What is BlobTxt?

BlobTxt is a Markdown editor for writers and researchers. It is a hybrid design that combines many things, notably including the following:

1. Quick and fragmentary thinking afforded by a note-taking app;
2. Careful organization of drafts and longer sessions of focused writing, typically done in a conventional document editor like MS Word or Apple Pages;
3. The distinct oragnization chain of a "repository" used by developers.

BlobTxt is meant to be part of the user's wider toolkit. It is not meant to replace a conventional Word document, nor is it meant to replace something like Zotero. Instead, BlobTxt is meant to help you get from a handful of ideas to your first or second draft.

### 1.2. Why not a Word document?

Conventional `.docx` editors pose two problems for me. First, formatting features such as paragraph styles, reference formatting, and typography, is always present. That feels intrinsic to writing, but it isn't; it's intrinsic to the tool. Word is built for making it easy to see how documents will be printed on paper. One's usage of the tool is bound to that design. Most of that formatting, however, *can* belong at the end of the process. Second, I have astigmatism and easily-tired eyes, and these proprietary apps limit how much I can change their appearance.

### 1.3. Why not an existing text editor?

This is what I used for a while. I've tried iA Writer for Markdown files, and I've also tried setting up VS Code to be more Markdown-canonical. The two approaches posed different problems. iA Writer is, again, proprietary software. Even worse, it's *opinionated*; the developers have a clear and narrow vision of what the app is meant to be. VS Code is the opposite. Its ecosystem is humongous, and the app has a lot of bells and whistles that I, when not working with code, simply don't need.

### 1.4. Why not LaTeX?

LaTeX is useful. However, I find that Markdown is better for the writing, researching, and brainstorming parts (basically the first two of the three "workflows" mentioned earlier that BlobTxt intends to combine).

## 2. Authors and Credits

The app was designed by June Jung. The codebase was built with Claude Code by Anthropic. The actual text editor portion of the app is built on [CodeMirror 6](https://codemirror.net). The editor is wrapped inside the app through Apple's `WKWebView` library.

## 3. Install

Build 0.2.0 is available in `misc_resources/distro/` as a compressed `.app` file. Unzip it and move it to your `/Applications/` folder.

Please be aware that BlobTxt has undergone a major refactor from the previous architecture, FishTxt. Some of the features are yet to be rebuilt, and new features are still being planned. The current package is very minimal.

# BlobTxt

## 1. About
### 1.1. What is BlobTxt?

BlobTxt is a Markdown editor for writers and researchers. It is a hybrid design that combines many things, notably including the following:

1. Quick and fragmentary thinking afforded by a note-taking app;
2. Careful organization of drafts and longer sessions of focused writing, typically done in a conventional document editor like MS Word or Apple Pages;
3. The distinct oragnization chain of a "repository" used by developers.

### 1.2. Why not a Word document?

Conventional `.docx` editors pose three problems for me. 

First, too many features are constantly present, cluttering the view and the mind. They may feel intrinsic to writing, but they aren't; they are intrinsic to the tool. Apps like MS Word or Google Docs are built for easily seeing how documents will appear in print. One's usage of the tool is bound to that design. The idea behind a Markdown editor, in contrast, is that most of that formatting, referencing, layout work, etc. *can* belong at the end of a process. 

Secondly, I have astigmatism and easily-tired eyes, and these proprietary apps are limited as to how much I can change their appearance.

Lastly, using git, especially `git diff`, is just a nightmare with `.docx` formats.

### 1.3. Why not use an existing text editor?

This is actually what I did for a while. I've tried [iA Writer](https://ia.net/writer), which pretty much have the same design intentions as BlobTxt, in that it seeks to *completely remove* the visual clutter that is typical of document editors. I've also tried setting up VS Code to be more Markdown-canonical. 

The two approaches posed different problems. iA Writer is, again, proprietary software. Even worse, it's very *opinionated*; the developers have a clear and narrow vision of what the app is meant to be. VS Code is the opposite. Its ecosystem is humongous, and the app has a lot of bells and whistles that, when not working with code, I simply don't need.

### 1.4. Why not LaTeX?

LaTeX is useful. However, I find that Markdown is better for writing, researching, and brainstorming (basically the first two of the three "workflows" mentioned earlier that BlobTxt intends to combine).

BlobTxt is intended as part of a user's wider toolkit. At a certain point, of course, you'll need to take care of page layout and whatnot. I personally use [pandoc, a universal document converter](https://pandoc.org) for PDF exports and printing. Additionally, I have my own set of [Markdown tools written in Python](https://github.com/guruk-cat/md-tools) for organization and file operations.

## 2. Authors and Attributions

The app was designed by June Jung. The codebase was built with Claude Code by Anthropic. 

The following are JS dependencies for the editor portion of the app, all used under MIT license:

- The actual text editor is built on [CodeMirror 6](https://codemirror.net).
- It also uses [lezer](https://lezer.codemirror.net) for parsing.
- [KaTeX](https://katex.org) is used for rendering math expressions written with LaTeX syntax.

## 3. Build Info and Installation

The app is built in Swift, although the user-facing text editor runs inside a JS environment wrapped via WKWebView. This means that BlobTxt is unfortunately only available on macOS. 

Alpha (0.3.5) is available in `misc_resources/distro/` as a compressed `.app` file. Unzip it and move it to your `/Applications/` folder.

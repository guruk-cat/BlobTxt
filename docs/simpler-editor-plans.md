# Trying Out a Simpler Approach to the Editor

## 1. Background
### 1.1. Post-Refactor State
The editor went through a refactor, to accommodate for the app-wide transition from using TipTap-based JSON file formats to using Markdown. The editor has sticked with the original appearance, including the fact that all formatting is done from the format toolbar. Markdown-specific formatting characters (such as hastags for headings and [\^N] for footnotes), are stripped from the user-facing side of EditView. Internal serialization and de-serialization handles all of that. 

The current approach has caused issues. The implementation and the bug fixes have been not as easy as I had expected or hoped. Hence, I want to try out a simpler approach.

### 1.2. Docs
The documentation of the current codebase is included in `docs/editor.md`, and the docs produced during planning and implementation of the refactor, respectively, can be found in `docs/refactor/plans/scoped-plan-2.md` and `docs/refactor/logs/pass-2-log.md`.

## 2. Simpler Approach
### 2.1. Overview

I want to rebuild the editor to be a simple *text editor* with syntax indication (i.e., font size, font color) specific to Markdown -- effectively making it a Markdown editor. This way, there's no complicated deserialization involved.

For footnotes, we'll assume the following convention, which is not too different from the currently implemented approach:

```Markdown
A salmon is big. But a whale is bigger.[^whale]

[^whale]: But the ocean is even bigger!
```

Thus, the footnote reference can be any string (including numbers) as long as the user remembers to not conflict two or more of them.

### 2.2. Toolbar

The toolbar will retire, along with the chrome buttons that existed in the same VStack near the top-right corner of the editor.

### 2.3. Syntax Indication

Formatting characters that are not included can be printed with a reduced saturation/luminosity. These include hastags, astericks, brackets, etc.

Stuff that's inside the formatting characters (e.g., bold text) can be displayed accordingly. Bold text bold, italics displayed italicized, etc. Hyperlinkes can be different colors. Headings can be in larger font size, etc.

## 3. Questions

The syntax indication means that there's still some kind of parsing that's required. But it would still eliminate potential bugs with caret locations and footnotes parsing. I'd still want to know if there's not *that* much to be gained from this.

An a different note, if something like this were to be implemented, I wonder if something like Milkdown or remark would be not needed at all. 

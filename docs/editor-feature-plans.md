# Editor Feature Planning

Before planning and implementing the features outlined below, I want a research conducted on relevant parts of the documentations of the CodeMirror 6 library. The goal is to utilize what the library already offers, and, by the same token, to avoid fighting against the usage patterns intended and expected by the developer.

For each feature or feature group, what I'd like at this moment is a report on how feasible it is, and if feasible enough, a brief explanation of how it'd be implemented. If the changes are trivial, it will be noted, and you will be asked to implement it right away.

These are several, not always related items; launch explorer agents when applicable.

Please don't do guess-work as to how to modify defaults provided in the CodeMirror library. That has led to problems in the past.

## 1. Caret

I want to have some more control over the appearance and the behavior of the caret. Right now, the caret's positioning and its blinking mechansisms seem to be those built into the library by deafult. 

The editor's text current uses a double-spaced line gap. The caret is positioned such that the bottom of the caret lines up with the bottom of the letters. However, I want the caret to be vertically centered along the letters, so that there is equal space that the caret stretches above and below the letters (that is, neglecting the vertical span of certain characters).

The caret's blinking behavior have some sort of fade that I don't like. I want to override it with a simpler fade/blink behavior.

## 2. Headings

Right now headings have different font sizes. I want to remove this. Headings have same font size as body text, but retains their bold weight. Implement this right away when you are ready.

## 3. Split view

I want to be able to view two Blobs, or different portions of the same blob, side-by-side.

## 4. Footnote auto-arranging

I want a new menu bar item (so, this would require a new notification on the Swift side, and a listener on the JS side). It will trigger the following behavior in Blobs that contain footnotes.

The editor walks through all the footnote references and definitions. Then, it renames *all* the labels (i.e., the "label" in [\^label]), as integers starting at 1, according to the order in which the *in-line* reference appears. Then, all the definition blocks are stripped away and re-appended at the bottom of the document.

## 5. Footnote tooltip

Hovering on the in-line reference opens a tooltip with the definition content.

## 6. Fully custom search panel

Customizing the search panel has been annoying. I wonder if a fully custom UI can be built, but utilizing the exiting functions for the search features. I believe there are typescript files in the git repo for the search extension.

# Colors in BlobTxt

## 1. Files

AppColors (`BlobTxt/Sources/Services/AppColors.swift`) loads the color palettes from `BlobTxt/Resources/colors.json`; then, AppColors exposes the active palette as SwiftUI `Color`s, and serializes it for the editor (both as the document-start CSS injection and the `updateConfig` color dict).

## 2. Layout and Roles

### 2.1. Window Layout, Broadly

The window contains, usually, only two things. An editor and a sidebar. The sidebar has a floating look, but the background color behind that floating, rounded rectangle is the same color as the editor background. In effect, what the user sees is: a plain surface that covers the whole window, with some portion of it on the right side displaying text, and a sidebar floating and fixed to the left side of the window.

BlobTxt uses the old-school title bar on top of the window, instead of the unified toolbar that many apps began to ship with beginning with macOS Tahoe. The window title bar is just a plain bar with the three traffic light buttons, the title string, and nothing else. It's an overall minimal window. 

### 2.2. Editor and UI Groups

Each palette has two groups. The first group is the "editor" group, used within the editor (rendered by the JS side of the code), as well as a handful of Swift files that govern editor-related UI or UI that otherwise needs to mimic the appearance of the editor.

The second group is the "UI" group, almost exclusively used by the Swift side of the code. These colors are used for various panels and app chrome outside of the editor.

In `colors.json`, each group has, and is led by, a "type" key. The editor group simply has `type`, and the UI group has `type_ui`. This key specifies whether the palette group is "light" (dark text on light background), or is "dark" (light text on dark background).

## 3. Usage: Editor Group

### 3.1. Main colors

The editor at large uses `surface` as the background. 

`surface_sunken` is used for inset wells, hover tooltips, etc.

`border` is used to draw outlines for elements that use `surface_sunken`, against the editor background which is in `surface`.

`chrome_panel` is used for panels within the editor (such as the search panel).

### 3.2. Font colors

`text_body` is the primary font color for body text in the editor. Its legibility against `surface` dictates the luminosity contrast of the overall palette.

`text_heading` is used for headings in blobs.

`text_muted` is used for syntax coloring where text needs to be inconspicuous but still legible. Typically, this color will mirror the hue family of the `surface` background.

`text_resting` is somewhere in between `text_body` and `text_muted`. It is conspicuous and legible but not eye-catching in any way. Typically, this color will mirror the hue family of the `surface` background, but at a higher luminosity than `text_muted`.

### 3.3. Tertiary colors

`meta_indication` is the primary source of accent. It is used for the editor caret, highlight selection, certain parts of syntax highlighting, and buttons when hovered.

`meta_confirmation` is used to indicate that a process was completed successfully. Usually, this is some sort of I/O task, such as saving a blob to disk. When possible, we use green, given that the background is not already green.

## 4. Usage: UI Group

Most key names in the UI group have the `ui_*` prefix, and otherwise mirror the names of the Editor group colors. 

### 4.1. Main colors

`ui_surface` is the equivalent of `surface`.

`ui_sunken` is the equivalent of `surface_sunken`.

`ui_border` is the equivalent of `border`.

### 4.2. Font and tertiary colors

All `ui_text_*` colors are equivalent to corresponding `text_*` colors. Same with `ui_indication` and `ui_confirmation`.

`git_*` colors are used for git-tracking in the navigator. The navigator primarily uses `ui_surface` with overlays of `ui_sunken`, so `git_*` colors need to be legible against those backgrounds.

Two colors serve as the main source of contrast against the background colors: `ui_text_heading` and `ui_indication`.

# 5. Wildcard(s)

`window_bar` is used for the app window's top bar, where the three traffic light buttons are held. This is set similar to `surface` with some luminosity difference. After all, the editor takes up a large portion of the window. 

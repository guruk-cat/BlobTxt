# Plans: Page Layout Customization Panel

## 1. General Notes on UI
### 1.1. Split

The panel is split to a left column (at 200px) and a right column (the remainder). The left column shows a list of available layout profiles, with options to add or remove custom ones. The right column holds the controls for tweaking profiles. 

### 1.2. Colors

The panel is a Swift-level UI element, and therefore uses the "UI group" from AppColors, unless otherwise noted.

## 2. Left Column
### 2.1. General layout

The column is basically a `VStack`. It uses `ui_surface` as its background. It should have, in the following order from top to bottom:

1. Heading, that reads "Layout Profiles."
2. A scrollable list of available profiles. At the bottom of the list is a "+ Add a new profile" row that is clickable. 
3. A footer button whose appearance is gated.

### 2.2. Heading

Font color should use `uiTextHeading`.

Margins and such should be practically identical to the left column of the Merge Blobs panel, of which the details are as follows.

The panel itself is a `ZStack(alignment: .topLeading)` that layers the title on top of `stageBody`. (The layout panel doesn't need to follow this, just including this info for context.) The panel title's padding is applied directly:

- `.padding(.horizontal, 18)` — left and right
- `.padding(.vertical, 14)` — top and bottom

No additional wrapper padding exists around `panel`. The `GeometryReader` in `body` only sets a `frame` and a `position`, so the values above are the title's complete margins.

Each stage view that is stacked on top (`MergeSelectionStage`, `MergeHeadingsStage`, `MergeMetadataStage`) defines two constants:

| Constant | Value | Purpose |
| --- | --- | --- |
| `topInset` | 44 pt | Pushes scroll content below the title overlay |
| `bottomInset` | 56 pt | Pushes scroll content above the footer overlay |

These are applied as `.padding(.top, topInset)` on the `VStack` inside each stage's `ScrollView`. They affect scroll content placement only, not the title itself. But this should also be considered for consistency's sake.

### 2.3. Scrollable list

Each row in the list displays the name of each available profile. With the exception of the default profile, each row is right-clickable, and the context menu presents "Edit", "Duplicate," and "Remove." Clicking on the row (lef-click) is identical to the "Edit" menu item; it opens the corresponding profile in the right-side column of the panel. The "Duplicate" action forks the profile; it creates an identical profile and appends "(n)" to the end of the name, where n is an integer counting up from 2.

The profile name is displayed in `uiTextResting` color. The row responds to mouse-hover and selection (i.e., being actively edited on the right column of the panel), with a row-specific background that looks like this:

```swift
private var rowBackground: Color {
    } if isSelected {
        return appColors.uiSunken.opacity(0.5)
    } else if hovering {
        return appColors.uiSunken.opacity(0.25)
    } else {
        return .clear
    }
```

At the bottom of the list is a special row that reads: "+ Add a new profile." This row should use `uiTextMuted` for font, which glows in `uiTextBody` when hovered. Clicking on this row creates a new profile identical to the default, named "Untitled Profile," and immediately opens it in the right-side column.

Names are ordered alphabetically, with the exception of the default profile which is pinned at the top.

### 2.4. Footer

Below the scrollable list will be a "Exit" button. This is *not* the "Cancel" button that cancels the editing or creation of a profile. The exit button is gated on whether there's a profile being actively edited on the right side of the panel; it is displayed only when there is none. When clicked, it closes out the panel and tells the app to return to the "File Operations" sidebar panel. This is the same behavior as the Merge Blobs panel when op is cancelled, whose implemenation, for reference, is as follows:

```swift
private struct SecondaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hovering ? appColors.uiTextBody : appColors.uiTextResting)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
```

In the Merge Blobs panel, the button above is used like this:

```swift
private var footer: some View {
    VStack {
        Spacer()
        HStack {
            if let prev = stage.previous {
                SecondaryButton(title: "Back") { withAnimation(.easeInOut(duration: 0.2)) { stage = prev } }
            } else {
                SecondaryButton(title: "Cancel", action: onCancel)
            }
            Spacer()
            
            // A different button for "Finish." Omitted for concision.

        }
        .padding(18)
    }
}
```

The layout *logic* above does not need to be mirrored. Code is provided so that margins can be calculated accordingly for sake of consistency.

Additionally, the Merge Blobs panel is displayed over the app in `ContentView` like this:

```swift
.overlay {
    if isMergingBlobs {
        MergeBlobsPanel(onCancel: cancelMergeBlobs, onFinish: finishMergeBlobs)
    }
}
```

The Merge Blobs panel's cancelation results, in `ContentView`, the following call:

```swift
private func cancelMergeBlobs() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        isMergingBlobs = false
        activePanel = .opsControl
        isSidebarOpen = true
    }
}
```

The Page Layout panel's cancelation should result in the same return to the File Ops sidebar panel.

## 3. Right Column

The remaining portion of the panel uses the same `uiSurface` for the background. Unless otherwise noted, layout tweaks are grouped as instances of `GroupBox`, using `uiSunken` for background color and `uiBorder` for the box border. Text inside a GroupBox will be either `uiTextBody` or `uiTextResting` depending on the use. Certain GroupBoxes will be additionally grouped into sections, of which the label, if specified below, should be displayed in the `uiIndication` color.

For GroupBox rows that roughly follow a `label: value` format, the label should use `uiTextResting` and the value should use `uiTextBody`.

For now, we will include basic controls, with room for growth in the future.

### 3.1. Naming

First GroupBox is the profile name. This is a one-row GrouBox:

1. "Name:" an editable text field

No special boxing for the text field; the GroupBox is the visual ROI, like how iOS settings app does it. Pressing enter confirms the edit and de-focuses the text field.

### 3.2. Styles

A "style" refers to the font family, font size, etc., that pertains to a particular node block type: H1 heading, H2 heading, and so on; body text; blockquotes; footnotes; lists; hyperlinkes; image captions; and so on.

This will be a "section" of multiple GroupBoxes, as explained above.

#### 3.2.1. Body text

1. "Font family:" a drop down menu of available fonts. 
2. "Font size:" text field
3. "Alignment:" a drop down menu of left/right/justified/centered
4. "Auto-hyphenation:" an on/off switch

Auto-hyphenation means that when text is line-wrapped, long words are hyphenated in order to keep word spacing relatively consistent. If this not trivial to implement, flag it during planning stage before moving on.

#### 3.2.2. Headings

For now, this should just follow body text font family, and let let `weasyprint` and `pandocs` determine how to style them otherwise. Just put a GroupBox with the caption "Headings controls yet to be implemented."

#### 3.2.3. Others

Others will simply follow whatever font family body text uses, and let `weasyprint` and `pandocs` determine how to style them. Detailed tweaks are deferred to the future. This does not need to be mentioned or indicated in the app or the code.

### 3.3. Page

This will be another section.

#### 3.3.1. Paper

1. "Paper size:" a drop down menu for common sizes (letter, A4, etc.)
2. "Orientation:" drop down menu for portrait/horizontal

#### 3.3.2. Margins

1. "Top margin:" [size] in.
2. "Bottom margin:" [size] in.
3. "Side margins:" [size] in.

#### 3.3.3. Pagination

Pagination here means page numbers printed on each page (rendered via weasyprint's `@page` margin boxes), not page breaking.

1. "Page numbers:" on/off switch

## 4. Defaults

For any component not mentioned here, assume that we are letting `weasyprint` and `pandocs` determine how to style them. 

Figure numbering for captions should be added by default. Option for turning it off is deferred.

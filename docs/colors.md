# Design Principles for BlobTxt Color Palettes

## BlobTxt's UI Layout

With the unifieid, macOS-level toolbar/window title bar at the top, the app's window presents the following elements in order, from left to right:

- Sidebar panels. Expandable and collapsible.
- Editor. Either present or blank space with same background color.

## Mapping colors to usage

The following are key values in `colors.json` and their corresponding usage in the BlobTxt app.

| Key | Usage |
| --- | ----- |
| `type` | either "dark" or "light." Used by `AppColors.palettes(ofType:)` to filter palette lists (e.g., the "Light palette" picker in follow-system mode shows only light palettes). |
| `surface` | background for the text editor and cards in the "search" panel of the sidebar |
| `surface_sunken` | background for the floating island of sidebar toggle buttons; background for certain other buttons |
| `surface_raised` | overlayed with an `opacity` argument when an element is selected or hovered |
| `border_card` | a thin outline around folder and blob cards in the dashboard |
| `chrome_panel` | background for expandable sidebar panels (file navigator, outline, search) |
| `chrome_toolbar` | color of the window title bar |
| `text_body` | main body text in the editor and cards; certain hovered elements in the sidebar |
| `text_resting` | list items in the file navigator and similar contexts where legibility matters but prominence does not |
| `text_muted` | inactive UI elements that can be clicked; used to make elements inconspicuous; often hovers in `text_body` when hovered |
| `text_heading` | headings in the editor; headings and section labels in sidebar panels; accent for selected folder/blob in the file navigator; interactive elements that appear with headings (chevrons, back-buttons) |
| `meta_indication` | cursor color; active formatting buttons in the editor toolbar; floating island button that corresponds to a sidebar panel actively open; certain buttons when hovered |
| `meta_confirmation` | success states (e.g., save confirmation, moved blob into folder) |
| `destructive` | delete-related features; rarely visible |

## Luminosity Contrast

BlobTxt's palettes are intentionally medium-contrast. Legibility is maintained through slight differences in hue and saturation *in addition to* differences in luminosity. Sharp contrast in luminosity is avoided to reduce eye strain.

When calculating, comparing, or evaluating luminosity of certain color roles or the whole palette, a weighted luminosity is used: 0.2126R + 0.7152G + 0.0722B. Moreover, when calculating the average luminosity of a palette, colors that occur rarely in the UI are excluded from this calculation. These are the `meta_*` colors and `destructive`.

## Key Contrast Pairs

The followings are the most legibility-critical pairings in the UI:

- `text_body` over `surface` (e.g., body text in editor). This is by far the most important. The luminosity gap between these two should be usually higher than the gap between other elements.
- `text_resting` over `chrome_panel` (e.g., file navigator list).

## Details on Text and Foreground Colors

The text roles form a spectrum from hue-close to hue-distinct relative to the *surface* background. The following information should be carefully considered when creating new palettes:

**`text_muted`** is used for inconspicuous, inactive elements that don't need to draw attention. Because it appears frequently and at low prominence, it should stay very close to the surface hue family — essentially a desaturated, lightened/darkened version of it. Too much hue deviation here would create visual noise.

**`text_resting`** serves a similar role to muted but where legibility still matters. It also stays within the surface hue family, slightly lighter/darker and more neutral than `text_muted`, but should not introduce a distinct hue.

**`text_body`** is the most-used foreground color. Because it appears constantly, it cannot be too hue-distinct from the surface without causing eye strain. A shift toward a neighboring or near-neutral hue is appropriate; the goal is subtle differentiation in hue, not contrast in hue.

**`text_heading`** is used for headings and selected states, which appear less frequently. This creates room for more hue distinction. An adjacent or near-complementary hue to the surface works well here — the goal is an "accent-like" color that adds visual interest to headings. Avoid pure complementary pairings (e.g., green text on a red background), as these create vibration and strain even at medium contrast. Note that `text_heading` also appears over the chrome zone (e.g., panel headers, selected items in the file navigator). Thus, this color is chosen to remain legible and coherent over both the surface and chrome backgrounds.

**`meta_indication`** is a special case. Usually, it returns to the surface hue family, but at high saturation. But this color can afford to deviate more from the main hue family. The decision is made based on how much hue contrast `text_heading` provides (or doesn't provide).

**`meta_confirmation`** should be a distinct hue. When possible, green is preferred. However, if the main hue family of the palette is already green, a different color is acceptable.

**`destructive`** is functionally determined and independent of the palette's hue logic. It is red.

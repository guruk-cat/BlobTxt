import SwiftUI

// A single navigator row.
// Background color indication is a single priority chain (see `rowBackground`).
struct FileRowView: View {
    @EnvironmentObject var appColors: AppColors

    let node: FileNode
    let depth: Int
    let indicator: RowIndicator          // trailing status mark, resolved for the active mode
    let isExpanded: Bool
    let isSelected: Bool        // blob is the one open in the editor
    let isContext: Bool         // folder is the current context directory
    let isGlowing: Bool         // folder just received a dropped blob
    let isDropHighlighted: Bool // row lies inside the folder a drag is hovering into
    let isDragged: Bool         // this blob is the one currently being dragged
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onTap: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    // Manual drag gesture callbacks. `changed` reports the cursor location in `navCoordinateSpace`.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var hovering = false

    private let indentStep: CGFloat = 12

    var body: some View {
        // Blobs and folders are both draggable.
        // The gesture coexists with tap/contextMenu via `simultaneousGesture` and a minimum distance so a click still registers as a tap (and a folder still toggles). It is omitted while renaming so the text field keeps normal mouse behavior.
        if !isRenaming {
            rowCore.simultaneousGesture(dragGesture)
        } else {
            rowCore
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(navCoordinateSpace))
            .onChanged { onDragChanged($0.location) }
            .onEnded { _ in onDragEnded() }
    }

    // Reports this row's frame (in the shared coordinate space) so a drag can hit-test it.
    private var frameTracker: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFrameKey.self,
                value: [node.url: geo.frame(in: .named(navCoordinateSpace))]
            )
        }
    }

    private var rowCore: some View {
        HStack(spacing: 5) {
            leadingSymbol
            if isRenaming {
                renameField
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundColor(appColors.uiTextResting)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trackingIndicator
        }
        .padding(.leading, 6 + CGFloat(depth) * indentStep)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Collapse (don't remove) the dragged row: keeping the view alive preserves the gesture that owns `.onEnded`. Removing it would strand the drag state.
        .frame(height: isDragged ? 0 : nil)
        .opacity(isDragged ? 0 : 1)
        .clipped()
        .background(frameTracker)
        .background(rowBackground)
        .overlay {
            // Drop-confirmation glow, drawn above the background. Kept always-present (rather than conditional) so its opacity can fade out smoothly; hit testing is disabled so it never swallows row taps.
            RoundedRectangle(cornerRadius: 4)
                .fill(appColors.uiConfirmation)
                .opacity(isGlowing ? 0.3 : 0)
                .animation(.easeOut(duration: 0.45), value: isGlowing)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isRenaming { onTap() } }
        .contextMenu {
            Button("Rename", action: onStartRename)
            if !node.isDirectory && node.url.isBlobFile {
                // Reopening a blob already in a mini view focuses that window, so this is always enabled.
                Button("Open in Mini View") {
                    NotificationCenter.default.post(name: .openMiniView, object: node.url)
                }
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    // Single source of truth for the row's background tint. Order encodes priority.
    private var rowBackground: Color {
        if isDropHighlighted {
            return appColors.uiIndication.opacity(0.12)
        } else if isSelected {
            return appColors.uiSunken.opacity(0.5)
        } else if hovering {
            return appColors.uiSunken.opacity(0.25)
        } else if isContext {
            return .clear
        } else {
            return .clear
        }
    }

    // Inline text field shown while renaming. Enter commits; Escape cancels. Interacting with another row cancels the rename from the parent (which clears `isRenaming`), so there is deliberately no commit-on-focus-loss here.
    private var renameField: some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(appColors.uiTextBody)
            .focused($fieldFocused)
            .onAppear {
                fieldFocused = true
                // Select only the basename so typing replaces the name but keeps the extension (Finder-style). Deferred so the field editor exists first.
                DispatchQueue.main.async { selectBasename() }
            }
            .onSubmit(onCommitRename)
            .onExitCommand(perform: onCancelRename)
    }

    // Selects the name up to (but not including) the final extension in the focused field editor. Folders and extensionless names end up fully selected.
    private func selectBasename() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let full = renameDraft as NSString
        let ext  = full.pathExtension as NSString
        let length = ext.length == 0 ? full.length : full.length - ext.length - 1
        editor.setSelectedRange(NSRange(location: 0, length: max(length, 0)))
    }

    // Trailing git status indicator. "Nothing to show" (incl. non-git projects) resolves to `.none`.
    @ViewBuilder
    private var trackingIndicator: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .dot(let color):
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
        case .badges(let badges):
            HStack(spacing: 3) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge.letter)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(badge.color)
                }
            }
        }
    }

    // Chevron for folders (rotates when expanded); fixed file icon for blobs.
    @ViewBuilder
    private var leadingSymbol: some View {
        if node.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(appColors.uiTextResting)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, alignment: .center)
        } else {
            Image(systemName: node.url.isImageFile ? "photo" : "doc.text")
                .font(.system(size: 10))
                .foregroundColor(isSelected ? appColors.uiIndication : appColors.uiTextResting)
                .frame(width: 12, alignment: .center)
        }
    }
}

// Header action button
struct HeaderIconButton: View {
    @EnvironmentObject var appColors: AppColors
    let systemName: String
    let action: () -> Void

    @State private var hovering = false
    @State private var glowing = false

    var body: some View {
        Button {
            action()
            glowing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.3)) { glowing = false }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(
                    glowing ? appColors.uiConfirmation
                    : hovering ? appColors.uiIndication
                    : appColors.uiTextResting
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

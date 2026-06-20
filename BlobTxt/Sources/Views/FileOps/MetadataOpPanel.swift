import SwiftUI

// The Blob Metadata panel: a window-level overlay (same chrome as Page Layout) for editing the open blob's YAML front matter.
// Unlike the other file ops it is gated to the editor — it always targets `store.activeContent`, the blob open in the main window. The launch button is disabled when no blob is open, so this panel assumes one is present.
// Edits are buffered in local state and only written on Save; Cancel discards them. Both close the panel.
struct MetadataOpPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    // Closes the panel and returns to the File Ops sidebar (mirrors Page Layout's exit).
    let onExit: () -> Void

    // Buffered editable state. Sequence keys are wrapped in `MetaItem` so each row keeps a stable identity across edits (a plain `[String]` would collide on duplicate or blank entries).
    @State private var title = ""
    @State private var date = ""
    @State private var authors: [MetaItem] = []
    @State private var institutions: [MetaItem] = []

    @State private var escMonitor: Any?

    private let panelSize: CGFloat = 640
    // The form column is pinned to this width so the fields stay close to their old sidebar proportions inside the much wider overlay.
    private let formColumnWidth: CGFloat = 250
    private let rowSpacing: CGFloat = 12
    private let labelWidth: CGFloat = 64

    var body: some View {
        ZStack {
            // Dimming scrim; a tap does nothing, so the panel leaves only through Cancel/Save.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            GeometryReader { geo in
                panel
                    .frame(
                        width: min(geo.size.width - 80, panelSize),
                        height: min(geo.size.height - 80, panelSize)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .onAppear {
            syncFromStore()
            // Escape mirrors the footer's Cancel: discard and close.
            // Installed here so it wins over the editor behind the panel.
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                guard event.keyCode == 53 else { return event } // Escape
                onExit()
                return nil
            }
        }
        .onDisappear {
            if let mon = escMonitor { NSEvent.removeMonitor(mon); escMonitor = nil }
        }
    }

    // header band • form column • footer band — the same shared bands as the Page Layout panel.
    private var panel: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    scalarRow(key: "title", text: $title)
                    listSection(key: "authors", items: $authors)
                    scalarRow(key: "date", text: $date)
                    listSection(key: "institutions", items: $institutions)
                }
                .frame(width: formColumnWidth, alignment: .leading)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            footer
        }
        .background(appColors.uiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    private var header: some View {
        HStack {
            Text("Blob Metadata")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(appColors.uiTextHeading)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Rows

    // A single-value key: label and one field in one HStack.
    private func scalarRow(key: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            keyLabel(key)
                .frame(width: labelWidth, alignment: .leading)
            MetaField(text: text)
        }
    }

    // A sequence key: the label with an add button, then one field per entry, each with a remove button. Adding appends a blank row.
    private func listSection(key: String, items: Binding<[MetaItem]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                keyLabel(key)
                Spacer()
                Button { items.wrappedValue.append(MetaItem(value: "")) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(appColors.uiTextResting)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(items) { $item in
                HStack(spacing: 6) {
                    MetaField(text: $item.value)
                    Button {
                        items.wrappedValue.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(appColors.uiTextResting)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func keyLabel(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12))
            .foregroundColor(appColors.uiTextResting)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            SecondaryButton(title: "Cancel", action: onExit)
            Spacer()
            PrimaryButton(title: "Save", enabled: true) { commit(); onExit() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(appColors.surface)
    }

    // MARK: - Store sync

    private func syncFromStore() {
        let metadata = store.activeContent?.metadata ?? BlobMetadata()
        title = metadata.title
        date = metadata.date
        authors = metadata.authors.map { MetaItem(value: $0) }
        institutions = metadata.institutions.map { MetaItem(value: $0) }
    }

    // Writes the buffered edits into the open document and persists immediately, so metadata-only changes are not lost when the editor has nothing dirty to trigger a body save.
    private func commit() {
        guard let content = store.activeContent else { return }
        content.updateMetadata(BlobMetadata(
            title: title,
            authors: authors.map(\.value),
            date: date,
            institutions: institutions.map(\.value)
        ))
        content.save()
    }
}

// A sequence entry with a stable identity for `ForEach`, independent of its (possibly duplicate or blank) text value.
private struct MetaItem: Identifiable {
    let id = UUID()
    var value: String
}

// One editable metadata field. Buffered: it only mutates local state, so there is no per-field commit.
private struct MetaField: View {
    @EnvironmentObject var appColors: AppColors
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(appColors.uiTextBody)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(appColors.uiSunken))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(focused ? appColors.uiIndication : appColors.uiBorder, lineWidth: 1)
            )
    }
}

// MARK: - Footer buttons (same styling as the Page Layout panel)

private struct SecondaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hovering ? appColors.textBody : appColors.textResting)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PrimaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(enabled ? (hovering ? appColors.surface : appColors.metaIndication) : appColors.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(enabled && hovering ? appColors.metaIndication : appColors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(enabled ? appColors.metaIndication : appColors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = enabled ? $0 : false }
    }
}

#Preview {
    MetadataOpPanel(onExit: {})
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 1100, height: 760)
}

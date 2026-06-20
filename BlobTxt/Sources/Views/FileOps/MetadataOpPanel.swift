import SwiftUI

// The Blob Metadata panel, for editing the open blob's YAML front matter.
// Unlike the other file ops it is gated to the editor. It always targets `store.activeContent`, the blob open in the main window. (The launch button is disabled when no blob is open, so this panel assumes one is present.) Edits are buffered in local state and only written on Save; Cancel discards them. Both close the panel.
struct MetadataOpPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    // Closes the panel and returns to the File Ops sidebar.
    let onExit: () -> Void

    // Buffered editable state. Sequence keys are wrapped in `MetaItem` so each row keeps a stable identity across edits (a plain `[String]` would collide on duplicate or blank entries).
    @State private var title = ""
    @State private var date = ""
    @State private var authors: [MetaItem] = []
    @State private var institutions: [MetaItem] = []

    private let formColumnWidth: CGFloat = 260
    private let rowSpacing: CGFloat = 12
    private let labelWidth: CGFloat = 64
    private let fieldGap: CGFloat = 8
    private let controlWidth: CGFloat = 14

    var body: some View {
        // Escape mirrors the footer's Cancel: discard and close.
        FileOpsOverlay(onEscape: { onExit(); return true }) {
            panel.onAppear { syncFromStore() }
        }
    }

    // header band + form column
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
                // Indented past the header's leading edge so the form reads as nested under the title.
                .padding(.leading, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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

    // A single-value key: label, field, then the empty control gutter so the field ends where the list rows' fields do.
    private func scalarRow(key: String, text: Binding<String>) -> some View {
        HStack(spacing: fieldGap) {
            keyLabel(key)
                .frame(width: labelWidth, alignment: .leading)
            MetaField(text: text)
            Color.clear.frame(width: controlWidth, height: 0)
        }
    }

    // A sequence key: the label with an add button, then one field per entry, each with a remove button. Adding appends a blank row.
    private func listSection(key: String, items: Binding<[MetaItem]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: fieldGap) {
                keyLabel(key)
                Spacer()
                Button { items.wrappedValue.append(MetaItem(value: "")) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(appColors.uiTextResting)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: controlWidth)
            }

            ForEach(items) { $item in
                // Leading label slot aligns the field with the scalar rows; the × sits in the shared trailing gutter.
                HStack(spacing: fieldGap) {
                    Color.clear.frame(width: labelWidth, height: 0)
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
                    .frame(width: controlWidth)
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
        FileOpsFooter {
            SecondaryButton(title: "Cancel", action: onExit)
            Spacer()
            PrimaryButton(title: "Save", enabled: true) { commit(); onExit() }
        }
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

#Preview {
    MetadataOpPanel(onExit: {})
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 1100, height: 760)
}

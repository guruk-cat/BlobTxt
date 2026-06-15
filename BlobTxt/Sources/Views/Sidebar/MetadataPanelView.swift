import SwiftUI

// The Metadata panel: reads and edits the active blob's YAML front matter (title, authors, date,
// institutions). Edits are held in local state and pushed to `ProjectStore` as write-requests on
// field submit, focus loss, list add/remove, and when the panel closes. The store is the source of
// truth for the open blob's metadata, so the panel resyncs from it whenever a different blob loads.
struct MetadataPanelView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    // The blob whose metadata is shown. Nil means no blob is open, so the panel shows a placeholder.
    let activeEditorURL: URL?

    // Local editable state. Sequence keys are wrapped in `MetaItem` so each row keeps a stable
    // identity across edits (a plain `[String]` would collide on duplicate or blank entries).
    @State private var title = ""
    @State private var date = ""
    @State private var authors: [MetaItem] = []
    @State private var institutions: [MetaItem] = []

    private let verticalMargin: CGFloat = 8
    private let horizontalMargin: CGFloat = 6
    private let rowSpacing: CGFloat = 12
    private let labelWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            if activeEditorURL == nil {
                placeholder
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        scalarRow(key: "title", text: $title)
                        listSection(key: "authors", items: $authors)
                        scalarRow(key: "date", text: $date)
                        listSection(key: "institutions", items: $institutions)
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, verticalMargin)
        .padding(.horizontal, horizontalMargin)
        .onAppear { syncFromStore() }
        // A different blob loaded: reload the fields from the store's freshly parsed metadata.
        .onChange(of: store.activeMetadataURL) { _ in syncFromStore() }
        // Closing the panel is a final write-request, catching edits left in a still-focused field.
        .onDisappear { commit() }
    }

    // MARK: - Header

    // "BLOB METADATA" rendered in the exact style of the navigator's project-name header.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("BLOB METADATA")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(appColors.uiTextHeading)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private var placeholder: some View {
        VStack {
            Spacer()
            Text("Open a blob to edit its metadata.")
                .font(.system(size: 12))
                .foregroundColor(appColors.uiTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    // A single-value key: label and one field in one HStack.
    private func scalarRow(key: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            keyLabel(key)
                .frame(width: labelWidth, alignment: .leading)
            MetaField(text: text, onCommit: commit)
        }
    }

    // A sequence key: the label with an add button, then one field per entry, each with a remove
    // button. Adding appends a blank row without committing (nothing to persist until typed).
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
                    MetaField(text: $item.value, onCommit: commit)
                    Button {
                        items.wrappedValue.removeAll { $0.id == item.id }
                        commit()
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

    // MARK: - Store sync

    private func syncFromStore() {
        let metadata = store.activeMetadata
        title = metadata.title
        date = metadata.date
        authors = metadata.authors.map { MetaItem(value: $0) }
        institutions = metadata.institutions.map { MetaItem(value: $0) }
    }

    private func commit() {
        store.updateActiveMetadata(BlobMetadata(
            title: title,
            authors: authors.map(\.value),
            date: date,
            institutions: institutions.map(\.value)
        ))
    }
}

// A sequence entry with a stable identity for `ForEach`, independent of its (possibly duplicate or
// blank) text value.
private struct MetaItem: Identifiable {
    let id = UUID()
    var value: String
}

// One editable metadata field: a `surface` rectangle with `uiTextBody` text and a thin `borderCard`
// outline that turns `metaIndication` while focused. Commits on Enter and on focus loss.
private struct MetaField: View {
    @EnvironmentObject var appColors: AppColors
    @Binding var text: String
    let onCommit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(appColors.uiTextBody)
            .focused($focused)
            .onSubmit(onCommit)
            .onChange(of: focused) { isFocused in
                if !isFocused { onCommit() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(appColors.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(focused ? appColors.metaIndication : appColors.borderCard, lineWidth: 1)
            )
    }
}

#Preview {
    MetadataPanelView(activeEditorURL: URL(fileURLWithPath: "/tmp/preview.md"))
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 254)
}

import SwiftUI

// The final MB stage: name the merged blob and, optionally, give it front-matter metadata. 
// The actual file is created by `MergeBlobsPanel`'s Finish button, which reads the name and metadata back from the session.
// This stage keeps the session in sync on every edit. 
// Entries are mirrored into the session so they survive stepping back to earlier stages.
struct MergeMetadataStage: View {
    @EnvironmentObject var appColors: AppColors
    @ObservedObject var session: MergeSession

    @State private var name = ""
    @State private var title = ""
    @State private var date = ""
    @State private var authors: [MergeMetaItem] = []
    @State private var institutions: [MergeMetaItem] = []

    private let topInset: CGFloat = 44
    private let bottomInset: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            fieldsPane
                .frame(maxWidth: MergeBlobsPanel.metadataColumnWidth, maxHeight: .infinity)
                .background(appColors.uiSurface)
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appColors.uiSurface)
        }
        .onAppear { syncFromSession() }
        .onChange(of: name) { _ in pushToSession() }
        .onChange(of: title) { _ in pushToSession() }
        .onChange(of: date) { _ in pushToSession() }
        .onChange(of: authors) { _ in pushToSession() }
        .onChange(of: institutions) { _ in pushToSession() }
    }

    private var fieldsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("FILE NAME")
                    MergeMetaField(placeholder: "", text: $name)
                    Text("Created at the project root as “\(displayFileName).md”.")
                        .font(.system(size: 11))
                        .foregroundColor(appColors.uiTextMuted)
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("METADATA (OPTIONAL)")
                    scalarRow("title", text: $title)
                    listSection("authors", items: $authors)
                    scalarRow("date", text: $date)
                    listSection("institutions", items: $institutions)
                }
            }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // The name shown in the path hint; falls back to "merged" when the field is blank.
    private var displayFileName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "merged" : trimmed
    }

    // MARK: - Rows

    // The label on its own line above the field, matching the list sections.
    private func scalarRow(_ key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            keyLabel(key)
            MergeMetaField(text: text)
        }
    }

    // A sequence key: a label with an add button, and one removable field per entry.
    private func listSection(_ key: String, items: Binding<[MergeMetaItem]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                keyLabel(key)
                Button { items.wrappedValue.append(MergeMetaItem(value: "")) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(appColors.uiTextResting)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }

            ForEach(items) { $item in
                HStack(spacing: 6) {
                    MergeMetaField(text: $item.value)
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(appColors.uiIndication)
    }

    // MARK: - Session sync

    private func syncFromSession() {
        name = session.fileName
        title = session.metadata.title
        date = session.metadata.date
        authors = session.metadata.authors.map { MergeMetaItem(value: $0) }
        institutions = session.metadata.institutions.map { MergeMetaItem(value: $0) }
    }

    private func pushToSession() {
        session.fileName = name
        session.metadata = BlobMetadata(
            title: title,
            authors: authors.map(\.value),
            date: date,
            institutions: institutions.map(\.value)
        )
    }
}

// A sequence entry with a stable identity for `ForEach`, independent of its (possibly duplicate or
// blank) text value.
private struct MergeMetaItem: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

// One editable field: a `surface` rectangle with a thin `border` outline that turns
// `metaIndication` while focused. The parent observes the bound state to mirror edits into the session.
private struct MergeMetaField: View {
    @EnvironmentObject var appColors: AppColors
    var placeholder: String = ""
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(appColors.uiTextBody)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(appColors.uiSunken))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? appColors.uiIndication : appColors.uiBorder, lineWidth: 1)
            )
    }
}

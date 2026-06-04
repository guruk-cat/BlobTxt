import SwiftUI

struct BlobMetadataView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var selectedProjectID: UUID?
    @Binding var activeBlobID: UUID?

    @State private var titleDraft: String = ""
    @State private var authorDraft: String = ""
    @State private var wordCount: Int = 0
    // Held so onChange can save metadata before the active blob or project switches.
    @State private var prevBlobID: UUID? = nil
    @State private var prevProjectID: UUID? = nil

    private var activeBlob: Blob? {
        guard let pid = selectedProjectID,
              let bid = activeBlobID,
              let project = store.projects.first(where: { $0.id == pid }) else { return nil }
        return project.blobs.first(where: { $0.id == bid })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                editableFields
                Divider()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                autoFields
            }
        }
        .onAppear {
            prevBlobID = activeBlobID
            prevProjectID = selectedProjectID
            reload()
        }
        .onChange(of: activeBlobID) { newBlobID in
            saveFor(blobID: prevBlobID, projectID: prevProjectID)
            prevBlobID = newBlobID
            reload()
        }
        .onChange(of: selectedProjectID) { newProjectID in
            saveFor(blobID: prevBlobID, projectID: prevProjectID)
            prevProjectID = newProjectID
            reload()
        }
        .onChange(of: store.projects) { _ in reloadWordCount() }
        .onDisappear { saveFor(blobID: prevBlobID, projectID: prevProjectID) }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("METADATA")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(AppColors.shared.textHeading)
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Editable Fields

    private var editableFields: some View {
        VStack(spacing: 0) {
            metaField(label: "Title", text: $titleDraft, placeholder: "Document title")
            metaField(label: "Author", text: $authorDraft, placeholder: "Author")
        }
    }

    private func metaField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppColors.shared.textMuted)
                .padding(.leading, 12)
            HStack {
                TextField(placeholder, text: text)
                    .font(.system(size: 12))
                    .foregroundColor(activeBlobID != nil ? AppColors.shared.textBody : AppColors.shared.textMuted)
                    .textFieldStyle(.plain)
                    .disabled(activeBlobID == nil)
                    .onSubmit { saveFor(blobID: prevBlobID, projectID: prevProjectID) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(AppColors.shared.surfaceRaised))
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Auto Fields

    private var autoFields: some View {
        VStack(spacing: 0) {
            autoRow(label: "Words", value: activeBlobID != nil ? wordCount.formatted() : "—")
            autoRow(label: "Modified", value: activeBlob.map { relativeDate($0.updatedAt) } ?? "—")
        }
    }

    private func autoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textResting)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 {
            let mins = Int(seconds / 60)
            return "\(mins) minute\(mins == 1 ? "" : "s") ago"
        }
        if seconds < 86400 {
            let hours = Int((seconds + 1800) / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Data

    private func reload() {
        guard let blob = activeBlob else {
            titleDraft = ""
            authorDraft = ""
            wordCount = 0
            return
        }
        titleDraft = blob.title ?? ""
        authorDraft = blob.author ?? ""
        reloadWordCount()
    }

    private func reloadWordCount() {
        guard let pid = selectedProjectID, let bid = activeBlobID else {
            wordCount = 0
            return
        }
        wordCount = store.loadBlobWordCount(blobID: bid, in: pid)
    }

    private func saveFor(blobID: UUID?, projectID: UUID?) {
        guard let bid = blobID, let pid = projectID else { return }
        store.updateBlobMetadata(
            blobID: bid,
            in: pid,
            title: titleDraft.isEmpty ? nil : titleDraft,
            author: authorDraft.isEmpty ? nil : authorDraft
        )
    }
}

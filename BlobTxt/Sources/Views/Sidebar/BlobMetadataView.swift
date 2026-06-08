import SwiftUI

// Placeholder metadata panel for Step 3 compatibility.
// YAML front matter editing (title, author, tags) is deferred to the full sidebar refactor.
struct BlobMetadataView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeBlobURL: URL?

    @State private var wordCount: Int = 0
    @State private var modifiedDate: String = "—"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider().padding(.horizontal, 12).padding(.vertical, 8)
                autoFields
            }
        }
        .onAppear { reload() }
        .onChange(of: activeBlobURL) { _ in reload() }
    }

    private var headerRow: some View {
        HStack {
            Text("METADATA").font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundColor(AppColors.shared.textHeading)
            Spacer()
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 4)
    }

    private var autoFields: some View {
        VStack(spacing: 0) {
            autoRow(label: "File", value: activeBlobURL.map { $0.lastPathComponent } ?? "—")
            autoRow(label: "Words", value: activeBlobURL != nil ? wordCount.formatted() : "—")
            autoRow(label: "Modified", value: modifiedDate)
        }
    }

    private func autoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(AppColors.shared.textResting)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundColor(AppColors.shared.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 26)
    }

    private func reload() {
        guard let url = activeBlobURL else { wordCount = 0; modifiedDate = "—"; return }
        wordCount = store.loadBlobWordCount(at: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            modifiedDate = relativeDate(date)
        } else {
            modifiedDate = "—"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { let m = Int(seconds / 60); return "\(m) minute\(m == 1 ? "" : "s") ago" }
        if seconds < 86400 { let h = Int((seconds + 1800) / 3600); return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: date)
    }
}

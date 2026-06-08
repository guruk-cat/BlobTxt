import SwiftUI
import AppKit

// MARK: - Plain text field

private struct PlainTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isEnabled: Bool = true
    var textColor: NSColor
    var onSubmit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder; field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.isEnabled = isEnabled; nsView.textColor = textColor
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: (() -> Void)?
        init(text: Binding<String>) { _text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(); return true }
            return false
        }
    }
}

// MARK: - BlobSearchView

struct BlobSearchView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeBlobURL: URL?

    @State private var searchQuery: String = ""
    @State private var replaceText: String = ""
    @State private var singleBlobOnly: Bool = false
    @State private var allBlobResults: [ProjectStore.SearchResult] = []
    @State private var snippetMatches: [ProjectStore.SnippetMatch] = []
    @State private var activeSnippetIndex: Int? = nil
    @State private var showReplaceConfirm: Bool = false
    @State private var hoverSearch: Bool = false
    @State private var hoverReplace: Bool = false

    private var isBlobOpen: Bool { activeBlobURL != nil }
    private var replaceEnabled: Bool {
        guard !searchQuery.isEmpty else { return false }
        return singleBlobOnly ? !snippetMatches.isEmpty : !allBlobResults.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow; searchInputRow; replaceRow; toggleRow; dividerBar
            ScrollView { resultsContent.padding(.bottom, 8) }
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .onAppear { singleBlobOnly = false }
        .onChange(of: activeBlobURL) { newValue in
            if newValue == nil { singleBlobOnly = false; snippetMatches = []
                NotificationCenter.default.post(name: .clearSearchHighlights, object: nil) }
        }
        .alert("Are you sure?", isPresented: $showReplaceConfirm) {
            Button("Yes") { executeReplaceAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(replaceConfirmMessage) }
    }

    private var headerRow: some View {
        HStack {
            Text("SEARCH").font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundColor(AppColors.shared.textHeading)
            Spacer()
        }
        .padding(.top, 12).padding(.bottom, 8)
    }

    private var searchInputRow: some View {
        HStack(spacing: 6) {
            PlainTextField(placeholder: "Search…", text: $searchQuery, isEnabled: true,
                           textColor: NSColor(AppColors.shared.textBody), onSubmit: performSearch)
                .frame(height: 24).padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(AppColors.shared.surfaceSunken.opacity(0.6)))
            Button(action: performSearch) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                    .foregroundColor(hoverSearch ? AppColors.shared.surface : AppColors.shared.metaIndication)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(hoverSearch ? AppColors.shared.metaIndication : AppColors.shared.surfaceSunken))
                    .animation(.easeInOut(duration: 0.12), value: hoverSearch)
            }
            .buttonStyle(.plain).onHover { hoverSearch = $0 }
        }
        .padding(.bottom, 8)
    }

    private var toggleRow: some View {
        HStack {
            Text("Search this blob only").font(.system(size: 12))
                .foregroundColor(isBlobOpen ? AppColors.shared.textResting : AppColors.shared.textMuted)
                .padding(.leading, 2)
            Spacer()
            Toggle("", isOn: Binding(
                get: { singleBlobOnly },
                set: { newValue in
                    singleBlobOnly = newValue
                    if newValue { performSearch() }
                    else { snippetMatches = []; NotificationCenter.default.post(name: .clearSearchHighlights, object: nil) }
                }
            ))
            .toggleStyle(.switch).controlSize(.mini).tint(AppColors.shared.metaIndication).labelsHidden().disabled(!isBlobOpen)
        }
        .padding(.bottom, 8)
    }

    private var dividerBar: some View {
        Rectangle().fill(AppColors.shared.textMuted.opacity(0.2)).frame(height: 1).padding(.vertical, 8)
    }

    @ViewBuilder
    private var resultsContent: some View {
        if singleBlobOnly {
            if snippetMatches.isEmpty { if !searchQuery.isEmpty { emptyMessage } }
            else { VStack(spacing: 6) { ForEach(snippetMatches) { snippetCard(for: $0) } } }
        } else {
            if allBlobResults.isEmpty { if !searchQuery.isEmpty { emptyMessage } }
            else { VStack(spacing: 8) { ForEach(allBlobResults) { allBlobResultCard(for: $0) } } }
        }
    }

    private var emptyMessage: some View {
        Text("No matches.").font(.system(size: 12)).foregroundColor(AppColors.shared.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }

    private func allBlobResultCard(for result: ProjectStore.SearchResult) -> some View {
        let isActive = activeBlobURL == result.blob.url
        return ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                if let title = result.excerpt.title {
                    Text(title).font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(AppColors.shared.textHeading).lineLimit(2)
                }
                if let body = result.excerpt.bodyAttributed {
                    Text(body).font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AppColors.shared.textBody).lineLimit(4)
                } else if result.excerpt.title == nil {
                    Text("Empty").font(.system(size: 12, design: .monospaced).italic()).foregroundColor(AppColors.shared.textMuted)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading).background(AppColors.shared.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? AppColors.shared.metaIndication : AppColors.shared.borderCard, lineWidth: isActive ? 2 : 1)
                .shadow(color: isActive ? AppColors.shared.metaIndication.opacity(0.4) : .clear, radius: 6))

            Text("\(result.matchCount) match\(result.matchCount == 1 ? "" : "es")")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(AppColors.shared.metaIndication)
                .padding(.trailing, 10).padding(.bottom, 7)
        }
        .onTapGesture { activeBlobURL = result.blob.url }
    }

    private func snippetCard(for match: ProjectStore.SnippetMatch) -> some View {
        let isActive = activeSnippetIndex == match.occurrenceIndex
        return Text(highlightedSnippet(for: match))
            .font(.system(size: 12, design: .monospaced)).foregroundColor(AppColors.shared.textBody).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
            .background(AppColors.shared.surface).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? AppColors.shared.metaIndication : AppColors.shared.borderCard, lineWidth: isActive ? 2 : 1))
            .onTapGesture {
                activeSnippetIndex = match.occurrenceIndex
                NotificationCenter.default.post(name: .scrollToSearchResult, object: match.occurrenceIndex)
            }
    }

    private func highlightedSnippet(for match: ProjectStore.SnippetMatch) -> AttributedString {
        let snippet = match.snippet
        guard let range = snippet.range(of: searchQuery, options: .caseInsensitive) else { return AttributedString(snippet) }
        var result = AttributedString()
        result += AttributedString(String(snippet[snippet.startIndex..<range.lowerBound]))
        var highlight = AttributedString(String(snippet[range]))
        highlight.backgroundColor = AppColors.shared.surfaceRaised
        highlight.foregroundColor = AppColors.shared.textHeading
        result += highlight
        result += AttributedString(String(snippet[range.upperBound...]))
        return result
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            PlainTextField(placeholder: "Replace all with…", text: $replaceText, isEnabled: true,
                           textColor: NSColor(AppColors.shared.textBody))
                .frame(height: 24).padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(AppColors.shared.surfaceSunken.opacity(0.6)))
            Button(action: { if replaceEnabled { showReplaceConfirm = true } }) {
                Image(systemName: "arrow.2.squarepath").font(.system(size: 13, weight: .medium))
                    .foregroundColor(!replaceEnabled ? AppColors.shared.textMuted : hoverReplace ? AppColors.shared.surface : AppColors.shared.metaIndication)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(hoverReplace && replaceEnabled ? AppColors.shared.metaIndication : AppColors.shared.surfaceSunken))
                    .animation(.easeInOut(duration: 0.12), value: hoverReplace)
            }
            .buttonStyle(.plain).onHover { hoverReplace = $0 }
        }
        .padding(.bottom, 12)
    }

    private var replaceConfirmMessage: String {
        if singleBlobOnly {
            let n = snippetMatches.count
            return "You are about to replace \(n) occurrence\(n == 1 ? "" : "s") of \"\(searchQuery)\" in 1 blob."
        } else {
            let total = allBlobResults.reduce(0) { $0 + $1.matchCount }
            let blobs = allBlobResults.count
            return "You are about to replace \(total) occurrence\(total == 1 ? "" : "s") of \"\(searchQuery)\", spanning \(blobs) blob\(blobs == 1 ? "" : "s")."
        }
    }

    private func performSearch() {
        guard let projectURL = store.currentProject?.url,
              !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            allBlobResults = []; snippetMatches = []; return
        }
        if singleBlobOnly, let blobURL = activeBlobURL {
            activeSnippetIndex = nil
            snippetMatches = store.searchSnippets(at: blobURL, query: searchQuery)
            NotificationCenter.default.post(name: .searchAndHighlight, object: searchQuery)
        } else {
            allBlobResults = store.searchBlobs(in: projectURL, query: searchQuery)
        }
    }

    private func executeReplaceAll() {
        if singleBlobOnly, let blobURL = activeBlobURL {
            store.replaceAllInBlobs(at: [blobURL], find: searchQuery, replace: replaceText)
            NotificationCenter.default.post(name: .reloadEditorContent, object: blobURL)
        } else {
            let urls = allBlobResults.map { $0.blob.url }
            store.replaceAllInBlobs(at: urls, find: searchQuery, replace: replaceText)
            if let active = activeBlobURL, urls.contains(active) {
                NotificationCenter.default.post(name: .reloadEditorContent, object: active)
            }
        }
        performSearch()
    }
}

#Preview {
    BlobSearchView(activeBlobURL: .constant(nil))
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 270)
}

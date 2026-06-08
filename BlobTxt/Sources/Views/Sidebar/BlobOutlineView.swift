import SwiftUI

struct BlobOutlineView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeBlobURL: URL?

    @State private var headings: [ProjectStore.BlobHeading] = []
    @State private var collapsedIndices: Set<Int> = []
    @State private var hoveredIndex: Int? = nil
    @State private var activeHeadingIndex: Int = -1

    static let rowHeight: CGFloat = 26
    private static let baseIndent: CGFloat = 8
    private static let levelIndent: CGFloat = 12

    private func hasChildren(at index: Int) -> Bool {
        let level = headings[index].level
        for i in (index + 1)..<headings.count {
            if headings[i].level <= level { return false }
            return true
        }
        return false
    }

    private var visibleHeadings: [(index: Int, heading: ProjectStore.BlobHeading)] {
        var result: [(index: Int, heading: ProjectStore.BlobHeading)] = []
        var collapsedStack: [Int] = []
        for (index, heading) in headings.enumerated() {
            collapsedStack.removeAll { $0 >= heading.level }
            guard collapsedStack.isEmpty else { continue }
            result.append((index: index, heading: heading))
            if collapsedIndices.contains(index) { collapsedStack.append(heading.level) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                contentRows
            }
        }
        .onAppear { reload() }
        .onChange(of: activeBlobURL) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .activeHeadingChanged)) { notif in
            activeHeadingIndex = notif.object as? Int ?? -1
        }
    }

    private var headerRow: some View {
        HStack {
            Text("OUTLINE").font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundColor(AppColors.shared.textHeading)
            Spacer()
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private var contentRows: some View {
        if activeBlobURL == nil { emptyLabel("No blob open.") }
        else if headings.isEmpty { emptyLabel("No headings.") }
        else {
            ForEach(visibleHeadings, id: \.index) { entry in headingRow(entry.heading, index: entry.index) }
        }
    }

    private func headingRow(_ heading: ProjectStore.BlobHeading, index: Int) -> some View {
        let indent = Self.baseIndent + CGFloat(heading.level - 1) * Self.levelIndent
        let isActive = activeHeadingIndex == index
        return HStack(spacing: 0) {
            Text(heading.text).font(.system(size: 12)).foregroundColor(AppColors.shared.textResting).lineLimit(1)
            Spacer()
        }
        .padding(.leading, indent + 14).padding(.trailing, 8)
        .overlay(alignment: .leading) {
            Image(systemName: collapsedIndices.contains(index) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(!hasChildren(at: index) ? Color.clear : AppColors.shared.textResting)
                .frame(width: 14).padding(.leading, indent)
                .onTapGesture { if hasChildren(at: index) { toggleCollapse(at: index) } }
        }
        .frame(height: Self.rowHeight)
        .background(isActive ? AppColors.shared.surfaceRaised.opacity(0.3) : hoveredIndex == index ? AppColors.shared.surfaceRaised.opacity(0.15) : Color.clear)
        .overlay(isActive ? Rectangle().frame(width: 4).foregroundColor(AppColors.shared.textHeading) : nil, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hoveredIndex = $0 ? index : nil }
        .onTapGesture { NotificationCenter.default.post(name: .scrollToOutlineHeading, object: index) }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(AppColors.shared.textMuted)
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleCollapse(at index: Int) {
        if collapsedIndices.contains(index) { collapsedIndices.remove(index) } else { collapsedIndices.insert(index) }
    }

    private func reload() {
        guard let url = activeBlobURL else { headings = []; collapsedIndices = []; activeHeadingIndex = -1; return }
        headings = store.loadBlobHeadings(at: url)
        collapsedIndices = []
        activeHeadingIndex = -1
    }
}

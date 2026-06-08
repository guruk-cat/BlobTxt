import SwiftUI

enum SidebarPanel: Equatable {
    case navigator
    case blobOutline
    case search
    case metadata
}

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var isSidebarOpen: Bool
    @Binding var activePanel: SidebarPanel
    @Binding var activeBlobURL: URL?
    @Binding var navigatorExpandedFolderURLs: Set<URL>
    @Binding var navigatorSelectedFolderURL: URL?

    private let margin: CGFloat = 8
    private let radius: CGFloat = 12
    private let islandHeight: CGFloat = 40
    private let floatWidth: CGFloat = 254

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarOpen && activePanel == .navigator {
                FileNavigatorView(
                    activeBlobURL: $activeBlobURL,
                    expandedFolderURLs: $navigatorExpandedFolderURLs,
                    selectedFolderURL: $navigatorSelectedFolderURL
                )
                .frame(width: floatWidth).frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                .padding(.horizontal, margin).padding(.top, margin)
                .padding(.bottom, margin + islandHeight + margin).frame(width: 270)
            } else if isSidebarOpen && activePanel == .blobOutline {
                BlobOutlineView(activeBlobURL: $activeBlobURL)
                    .frame(width: floatWidth).frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                    .padding(.horizontal, margin).padding(.top, margin)
                    .padding(.bottom, margin + islandHeight + margin).frame(width: 270)
            } else if isSidebarOpen && activePanel == .search {
                BlobSearchView(activeBlobURL: $activeBlobURL)
                    .frame(width: floatWidth).frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                    .padding(.horizontal, margin).padding(.top, margin)
                    .padding(.bottom, margin + islandHeight + margin).frame(width: 270)
            } else if isSidebarOpen && activePanel == .metadata {
                BlobMetadataView(activeBlobURL: $activeBlobURL)
                    .frame(width: floatWidth).frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                    .padding(.horizontal, margin).padding(.top, margin)
                    .padding(.bottom, margin + islandHeight + margin).frame(width: 270)
            }
        }
        .frame(width: isSidebarOpen ? 270 : 0)
        .background(AppColors.shared.surface)
        .onReceive(NotificationCenter.default.publisher(for: .toggleNavigator)) { _ in togglePanel(.navigator) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in togglePanel(.search) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleOutline)) { _ in togglePanel(.blobOutline) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMetadata)) { _ in togglePanel(.metadata) }
    }

    private func togglePanel(_ panel: SidebarPanel) {
        if isSidebarOpen && activePanel == panel { isSidebarOpen = false }
        else { activePanel = panel; isSidebarOpen = true }
    }
}

#Preview {
    SidebarView(
        isSidebarOpen: .constant(true),
        activePanel: .constant(.navigator),
        activeBlobURL: .constant(nil),
        navigatorExpandedFolderURLs: .constant([]),
        navigatorSelectedFolderURL: .constant(nil)
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
}

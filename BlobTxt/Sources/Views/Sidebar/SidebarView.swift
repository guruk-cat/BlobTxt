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
    @Binding var selectedProjectID: UUID?
    @Binding var activeBlobID: UUID?
    // Navigator state is owned by ContentView so it survives focus mode (which removes SidebarView).
    @Binding var navigatorExpandedFolderIDs: Set<UUID>
    @Binding var navigatorSelectedFolderID: UUID?

    private let margin: CGFloat = 8
    private let radius: CGFloat = 12
    private let islandHeight: CGFloat = 40
    private let floatWidth: CGFloat = 254   // 270 - margin * 2

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarOpen && activePanel == .navigator {
                FileNavigatorView(
                    selectedProjectID: $selectedProjectID,
                    activeBlobID: $activeBlobID,
                    expandedFolderIDs: $navigatorExpandedFolderIDs,
                    selectedFolderID: $navigatorSelectedFolderID
                )
                .frame(width: floatWidth)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                .padding(.horizontal, margin)
                .padding(.top, margin)
                .padding(.bottom, margin + islandHeight + margin)
                .frame(width: 270)
            } else if isSidebarOpen && activePanel == .blobOutline {
                BlobOutlineView(
                    selectedProjectID: $selectedProjectID,
                    activeBlobID: $activeBlobID
                )
                .frame(width: floatWidth)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                .padding(.horizontal, margin)
                .padding(.top, margin)
                .padding(.bottom, margin + islandHeight + margin)
                .frame(width: 270)
            } else if isSidebarOpen && activePanel == .search {
                BlobSearchView(
                    selectedProjectID: $selectedProjectID,
                    selectedFolderID: .constant(nil),
                    activeBlobID: $activeBlobID
                )
                .frame(width: floatWidth)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                .padding(.horizontal, margin)
                .padding(.top, margin)
                .padding(.bottom, margin + islandHeight + margin)
                .frame(width: 270)
            } else if isSidebarOpen && activePanel == .metadata {
                BlobMetadataView(
                    selectedProjectID: $selectedProjectID,
                    activeBlobID: $activeBlobID
                )
                .frame(width: floatWidth)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.chromePanel))
                .padding(.horizontal, margin)
                .padding(.top, margin)
                .padding(.bottom, margin + islandHeight + margin)
                .frame(width: 270)
            }
        }
        .frame(width: isSidebarOpen ? 270 : 0)
        .background(AppColors.shared.surface)
        .onReceive(NotificationCenter.default.publisher(for: .toggleNavigator)) { _ in
            togglePanel(.navigator)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
            togglePanel(.search)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleOutline)) { _ in
            togglePanel(.blobOutline)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMetadata)) { _ in
            togglePanel(.metadata)
        }
    }

    private func togglePanel(_ panel: SidebarPanel) {
        if isSidebarOpen && activePanel == panel {
            isSidebarOpen = false
        } else {
            activePanel = panel
            isSidebarOpen = true
        }
    }
}

#Preview {
    SidebarView(
        isSidebarOpen: .constant(true),
        activePanel: .constant(.navigator),
        selectedProjectID: .constant(nil),
        activeBlobID: .constant(nil),
        navigatorExpandedFolderIDs: .constant([]),
        navigatorSelectedFolderID: .constant(nil)
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
}

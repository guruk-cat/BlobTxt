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
    @Binding var activeEditorURL: URL?

    private let margin: CGFloat = 8
    private let radius: CGFloat = 12
    private let islandHeight: CGFloat = 40
    private let floatWidth: CGFloat = 254   // 270 - margin * 2

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarOpen {
                panelContent
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

    // Navigator renders normally; the other three panels share a placeholder.
    @ViewBuilder
    private var panelContent: some View {
        if activePanel == .navigator {
            FileNavigatorView(activeEditorURL: $activeEditorURL)
        } else {
            unavailablePanel
        }
    }

    // Placeholder shown for panels not yet implemented.
    private var unavailablePanel: some View {
        VStack {
            Spacer()
            Text("This panel is not yet available.")
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        activeEditorURL: .constant(nil)
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
}

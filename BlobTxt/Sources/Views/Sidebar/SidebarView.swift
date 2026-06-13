import SwiftUI

enum SidebarPanel: Equatable {
    case navigator
    case scratchpad
    case gitControl
    case metadataControl
}

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var isSidebarOpen: Bool
    @Binding var activePanel: SidebarPanel
    @Binding var activeEditorURL: URL?
    // Genuine open request from a navigator row; saves the current blob before switching.
    let onRequestOpen: (URL) -> Void

    private let margin: CGFloat = 8
    private let radius: CGFloat = 12
    private let islandHeight: CGFloat = 40
    private let floatWidth: CGFloat = 254

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
                    // Slide in/out from the leading edge to match the island's expansion.
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: isSidebarOpen ? 270 : 0)
        .onReceive(NotificationCenter.default.publisher(for: .toggleNavigator)) { _ in togglePanel(.navigator) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleScratchpad)) { _ in togglePanel(.scratchpad) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGitControl)) { _ in togglePanel(.gitControl) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMetadata)) { _ in togglePanel(.metadataControl) }
    }

    // Navigator renders normally; the other panels share a placeholder.
    @ViewBuilder
    private var panelContent: some View {
        if activePanel == .navigator {
            FileNavigatorView(activeEditorURL: $activeEditorURL, onRequestOpen: onRequestOpen)
        } else if activePanel == .scratchpad {
            unavailablePanel1
        } else if activePanel == .gitControl {
            unavailablePanel2
        } else if activePanel == .metadataControl {
            unavailablePanel3
        }
    }

    // Placeholders shown for panels not yet implemented.
    private var unavailablePanel1: some View {
        VStack {
            Spacer()
            Text("Scratchpad is not yet available.")
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var unavailablePanel2: some View {
        VStack {
            Spacer()
            Text("Git control is not yet available.")
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var unavailablePanel3: some View {
        VStack {
            Spacer()
            Text("Metadata panel is not yet available.")
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func togglePanel(_ panel: SidebarPanel) {
        // Spring matches the island's own animation so the sidebar, editor reflow,
        // and island all move together when the sidebar is toggled.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            if isSidebarOpen && activePanel == panel { isSidebarOpen = false }
            else { activePanel = panel; isSidebarOpen = true }
        }
    }
}

#Preview {
    SidebarView(
        isSidebarOpen: .constant(true),
        activePanel: .constant(.navigator),
        activeEditorURL: .constant(nil),
        onRequestOpen: { _ in }
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
}

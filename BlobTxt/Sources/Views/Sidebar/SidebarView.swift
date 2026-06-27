import SwiftUI

// The sidebar is the file navigator — there is only one panel. This view is the
// sliding chrome (width, animation, surface) around FileNavigatorView.
struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var isSidebarOpen: Bool
    @Binding var activeEditorURL: URL?
    @ObservedObject var navigator: NavigatorModel
    // Genuine open request from a navigator row; saves the current blob before switching.
    let onRequestOpen: (URL) -> Void

    private let margin: CGFloat = 8
    private let radius: CGFloat = 12
    private let floatWidth: CGFloat = 254

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarOpen {
                // The panel spans the full window height; the floating island overlaps its bottom-left corner.
                FileNavigatorView(model: navigator, activeEditorURL: $activeEditorURL, onRequestOpen: onRequestOpen)
                    .frame(width: floatWidth)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: radius).fill(AppColors.shared.uiSurface))
                    .padding(.horizontal, margin)
                    .padding(.vertical, margin)
                    .frame(width: 270)
                    // Slide in/out from the leading edge to match the island's expansion.
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: isSidebarOpen ? 270 : 0)
        .onReceive(NotificationCenter.default.publisher(for: .toggleNavigator)) { _ in toggle() }
    }

    private func toggle() {
        // Spring matches the island's own animation so the sidebar, editor reflow, and island all move together when the sidebar is toggled.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            isSidebarOpen.toggle()
        }
    }
}

#Preview {
    SidebarView(
        isSidebarOpen: .constant(true),
        activeEditorURL: .constant(nil),
        navigator: NavigatorModel(),
        onRequestOpen: { _ in }
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
}

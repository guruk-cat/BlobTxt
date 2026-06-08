import SwiftUI
import AppKit

// Recent projects panel. Lists the last 10 opened project directories and provides
// an "Open Other…" button that presents NSOpenPanel to browse for any directory.
struct ProjectPickerPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    var onDismiss: () -> Void

    @State private var recentURLs: [URL] = []
    @State private var hoveredURL: URL? = nil
    @State private var dismissButtonHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("OPEN PROJECT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(AppColors.shared.textHeading)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            Divider().padding(.horizontal, 16)

            // Recent projects list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(recentURLs, id: \.path) { url in
                        recentRow(url)
                    }
                    if recentURLs.isEmpty {
                        Text("No recent projects.")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.shared.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider().padding(.horizontal, 16)

            // Footer: Open Other + Dismiss
            HStack(spacing: 8) {
                Button("Open Other…") {
                    openOtherPanel()
                }
                .font(.system(size: 13))
                .foregroundColor(AppColors.shared.textResting)
                .buttonStyle(.plain)
                .padding(.leading, 16)

                Spacer()

                Button { onDismiss() } label: {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(dismissButtonHovered ? AppColors.shared.surface : AppColors.shared.textResting)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(AppColors.shared.surfaceSunken)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .fill(dismissButtonHovered ? AppColors.shared.metaIndication.opacity(0.9) : AppColors.shared.surfaceSunken))
                        )
                }
                .buttonStyle(.plain)
                .onHover { dismissButtonHovered = $0 }
                .padding(.trailing, 16)
            }
            .padding(.vertical, 8)
        }
        .frame(width: 320, height: 400)
        .background(AppColors.shared.chromePanel)
        .onAppear { recentURLs = store.recentProjectURLs() }
    }

    private func recentRow(_ url: URL) -> some View {
        let isHovered = hoveredURL == url
        let isCurrent = store.currentProject?.url == url
        return HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundColor(isCurrent ? AppColors.shared.metaIndication : AppColors.shared.textResting)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundColor(isCurrent ? AppColors.shared.metaIndication : AppColors.shared.textResting)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.shared.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.shared.metaIndication)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(isHovered ? AppColors.shared.surfaceRaised.opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hoveredURL = $0 ? url : (hoveredURL == url ? nil : hoveredURL) }
        .onTapGesture {
            store.openProject(at: url)
            onDismiss()
        }
    }

    private func openOtherPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            store.openProject(at: url)
            onDismiss()
        }
    }
}

#Preview {
    ProjectPickerPanel(onDismiss: {})
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}

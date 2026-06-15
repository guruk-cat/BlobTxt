import SwiftUI

// The File Operations panel: the set of routes into file-level services (Merge Blobs, Page Layout for
// Print & PDF, etc.). Each service opens its own wider, window-level panel; this panel is just the
// launch points, plus any status indication.
struct FileOpsPanelView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    private let verticalMargin: CGFloat = 8
    private let horizontalMargin: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            // Each row routes to a window-level panel for its service. Page Layout is still a stub.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FileOpButton(
                        icon: "arrow.triangle.merge",
                        title: "Merge Blobs",
                        subtitle: "Combine blobs, arrange headings and footnotes."
                    ) {
                        NotificationCenter.default.post(name: .openMergeBlobs, object: nil)
                    }
                    FileOpButton(
                        icon: "doc.richtext",
                        title: "Page Layout",
                        subtitle: "Configure the layout for printing and PDF exports."
                    ) {
                        // TODO: open the Page Layout panel.
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, verticalMargin)
        .padding(.horizontal, horizontalMargin)
    }

    // "FILE OPERATIONS" rendered in the exact style of the navigator's project-name header.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("FILE OPERATIONS")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(appColors.uiTextHeading)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

// A large rounded-rectangle route button: icon, title, and a muted one-line subtitle, with a
// trailing chevron. Roughly SwiftUI-shaped without copying it exactly. The card lifts and its border
// turns `metaIndication` on hover.
private struct FileOpButton: View {
    @EnvironmentObject var appColors: AppColors
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(hovering ? appColors.uiIndication : appColors.uiTextResting)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(appColors.uiTextBody)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(appColors.uiTextResting)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(hovering ? appColors.uiIndication : appColors.uiTextResting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(appColors.uiSunken))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hovering ? appColors.uiIndication : appColors.uiBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    FileOpsPanelView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 254)
}

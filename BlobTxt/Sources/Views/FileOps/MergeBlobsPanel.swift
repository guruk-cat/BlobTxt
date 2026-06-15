import SwiftUI

// The Merge Blobs ("MB") panel: a window-level overlay that walks the user through merging several
// blobs into one. It is a single rounded rectangle split down the middle (left `chromePanel`, right
// `surface`), staged as selection → headings → metadata. Hosted by `ContentView` as a ZStack layer
// over a dimming scrim.
//
// This is the shell: stage routing, the split layout, and the footer navigation are in place; each
// stage's body is still a placeholder, filled in by later increments.
struct MergeBlobsPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    // Cancelled out of the flow: the host returns to the File Ops panel.
    let onCancel: () -> Void
    // Finished with a freshly created merged blob: the host opens it in the navigator.
    let onFinish: (URL) -> Void

    @State private var stage: Stage = .selection

    // The merge selection and ordering, shared across stages. Its own read-only navigator tree feeds
    // the selection stage's left pane.
    @StateObject private var session = MergeSession()
    @StateObject private var navigator = NavigatorModel()

    // The stages of the merge flow, in order.
    private enum Stage: Int, CaseIterable {
        case selection, headings, metadata

        var title: String {
            switch self {
            case .selection: return "Select Blobs"
            case .headings:  return "Adjust Headings"
            case .metadata:  return "Name & Metadata"
            }
        }

        var previous: Stage? { Stage(rawValue: rawValue - 1) }
        var next: Stage? { Stage(rawValue: rawValue + 1) }
        var isLast: Bool { next == nil }
    }

    var body: some View {
        ZStack {
            // Dimming scrim; blocks interaction with the editor underneath. A scrim tap intentionally
            // does nothing, so the flow is dismissed only through the explicit Cancel button.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            GeometryReader { geo in
                panel
                    .frame(
                        width: min(geo.size.width - 80, 736),
                        height: min(geo.size.height - 80, 640)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // The rounded-rectangle panel: stage body, a stage title, and the footer navigation, clipped to
    // one rounded shape with a card border.
    private var panel: some View {
        ZStack(alignment: .topLeading) {
            stageBody

            Text(stage.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(appColors.textHeading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            footer
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(appColors.borderCard, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    // The stage's main content. Selection and headings use the left/right split; metadata fills the
    // whole panel with `chromePanel`.
    @ViewBuilder
    private var stageBody: some View {
        switch stage {
        case .selection:
            MergeSelectionStage(navigator: navigator, session: session)
        case .headings:
            splitLayout(
                left: placeholder("Heading adjustments", on: appColors.chromePanel),
                right: placeholder("Preview", on: appColors.surface)
            )
        case .metadata:
            placeholder("Name & metadata", on: appColors.chromePanel)
        }
    }

    // Two equal halves with no gap; each fills its side and carries its own background.
    private func splitLayout<L: View, R: View>(left: L, right: R) -> some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, maxHeight: .infinity)
            right.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String, on background: Color) -> some View {
        ZStack {
            background
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(appColors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    // Cancel/Back on the leading corner, Continue/Finalize on the trailing corner.
    private var footer: some View {
        VStack {
            Spacer()
            HStack {
                if let prev = stage.previous {
                    secondaryButton("Back") { withAnimation(.easeInOut(duration: 0.2)) { stage = prev } }
                } else {
                    secondaryButton("Cancel", action: onCancel)
                }
                Spacer()
                if stage.isLast {
                    // TODO: replace with merged-file creation, then onFinish(newURL).
                    primaryButton("Finalize", enabled: true, action: onCancel)
                } else {
                    primaryButton("Continue", enabled: canContinue) {
                        if let next = stage.next { withAnimation(.easeInOut(duration: 0.2)) { stage = next } }
                    }
                }
            }
            .padding(18)
        }
    }

    // Whether the current stage may advance. Selection needs at least two blobs to merge.
    private var canContinue: Bool {
        switch stage {
        case .selection: return session.selected.count >= 2
        case .headings, .metadata: return true
        }
    }

    // Plain text button for Cancel/Back.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        SecondaryButton(title: title, action: action)
    }

    // Filled accent button that glows `metaIndication` on hover; dimmed and inert when disabled.
    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        PrimaryButton(title: title, enabled: enabled, action: action)
    }
}

private struct SecondaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hovering ? appColors.textBody : appColors.textResting)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PrimaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(enabled ? (hovering ? appColors.surface : appColors.metaIndication) : appColors.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(enabled && hovering ? appColors.metaIndication : appColors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(enabled ? appColors.metaIndication : appColors.borderCard, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = enabled ? $0 : false }
    }
}

#Preview {
    MergeBlobsPanel(onCancel: {}, onFinish: { _ in })
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 1100, height: 760)
}

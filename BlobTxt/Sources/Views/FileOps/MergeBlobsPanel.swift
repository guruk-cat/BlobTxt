import SwiftUI

// The Merge Blobs ("MB") panel: a window-level overlay that walks the user through merging several
// blobs into one. It is a single rounded rectangle split down the middle (left `chromePanel`, right
// `surface`), staged as selection → headings → metadata. Hosted by `ContentView` as a ZStack layer
// over a dimming scrim. This file owns the shell — stage routing, layout, footer navigation, and the
// final file write; each stage's body is its own view, and the merge transform lives in `MergeEngine`.
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
    }

    // The left pane (the working content) widens as the flow advances: 250 at selection, 285 at
    // headings, then half the panel (320) at metadata, so the working area grows toward the end.
    static let selectionColumnWidth: CGFloat = 250
    static let headingsColumnWidth: CGFloat = 285
    static let metadataColumnWidth: CGFloat = 320

    // Every stage uses the same panel size.
    private let panelWidth: CGFloat = 640

    var body: some View {
        ZStack {
            // Dimming scrim; blocks interaction with the editor underneath. A scrim tap intentionally
            // does nothing, so the flow is dismissed only through the explicit Cancel button.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            GeometryReader { geo in
                panel
                    .frame(
                        width: min(geo.size.width - 80, panelWidth),
                        height: min(geo.size.height - 80, 640)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // The rounded-rectangle panel
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

    // The stage's main content. 
    @ViewBuilder
    private var stageBody: some View {
        switch stage {
        case .selection:
            MergeSelectionStage(navigator: navigator, session: session)
        case .headings:
            MergeHeadingsStage(session: session)
        case .metadata:
            MergeMetadataStage(session: session)
        }
    }

    // MARK: - Footer

    // Cancel/Back on the leading corner, Continue/Finish on the trailing corner.
    private var footer: some View {
        VStack {
            Spacer()
            HStack {
                if let prev = stage.previous {
                    SecondaryButton(title: "Back") { withAnimation(.easeInOut(duration: 0.2)) { stage = prev } }
                } else {
                    SecondaryButton(title: "Cancel", action: onCancel)
                }
                Spacer()
                if stage == .metadata {
                    PrimaryButton(title: "Finish", enabled: canFinalize, action: finalize)
                } else {
                    PrimaryButton(title: "Continue", enabled: canContinue) {
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

    // The merged blob needs a name before it can be created.
    private var canFinalize: Bool {
        !session.fileName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Builds the merged document from a fresh disk read of the selected blobs, writes it as a new blob
    // at the project root (with the chosen name and metadata), and hands the new URL back to the host.
    private func finalize() {
        guard let root = store.currentProject?.url else { return }
        let merged = MergeEngine.merge(session: session) { store.readBody(url: $0) }
        guard let url = store.createBlob(
            named: session.fileName,
            metadata: session.metadata,
            body: merged.body,
            in: root
        ) else { return }
        onFinish(url)
    }
}

// Plain text button for Cancel/Back.
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

// Filled accent button that glows `metaIndication` on hover; dimmed and inert when disabled.
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

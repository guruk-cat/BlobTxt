import SwiftUI

struct MergeBlobsPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    // Cancelled out of the flow: the host returns to the File Ops panel.
    let onCancel: () -> Void
    // Finished with a freshly created merged blob: the host opens it in the navigator.
    let onFinish: (URL) -> Void

    @State private var stage: Stage = .selection

    // The merge selection and ordering, shared across stages. Its own read-only navigator tree feeds the selection stage's left pane.
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

    static let selectionColumnWidth: CGFloat = 250
    static let headingsColumnWidth: CGFloat = 285
    static let metadataColumnWidth: CGFloat = 320

    var body: some View {
        // Escape cancels the flow, mirroring the Cancel button.
        FileOpsOverlay(onEscape: { onCancel(); return true }) {
            panel
        }
    }

    // The actual panel
    private var panel: some View {
        ZStack(alignment: .topLeading) {
            stageBody
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }

            Text(stage.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.shared.uiTextHeading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

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

    // The shared footer band. Cancel/Back on the leading corner, Continue/Finish on the trailing corner.
    private var footer: some View {
        FileOpsFooter {
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
    }

    // Whether the current stage may advance.
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

    // Builds the merged document from a fresh disk read of the selected blobs, writes it as a new blob at the project root (with the chosen name and metadata), and hands the new URL back to the host.
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

#Preview {
    MergeBlobsPanel(onCancel: {}, onFinish: { _ in })
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 1100, height: 760)
}

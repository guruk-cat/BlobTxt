import SwiftUI

struct MergeBlobsPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    // Cancelled out of the flow: the host returns to the File Ops panel.
    let onCancel: () -> Void
    // Finished with a freshly created merged blob: the host opens it in the navigator.
    let onFinish: (URL) -> Void

    @State private var stage: Stage = .selection
    @State private var escMonitor: Any?

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

        var headingColor: Color {
            switch self {
            case .selection: return AppColors.shared.uiTextHeading
            case .headings:  return AppColors.shared.textHeading
            case .metadata:  return AppColors.shared.uiTextHeading
            }
        }

        var previous: Stage? { Stage(rawValue: rawValue - 1) }
        var next: Stage? { Stage(rawValue: rawValue + 1) }
    }

    static let selectionColumnWidth: CGFloat = 250
    static let headingsColumnWidth: CGFloat = 285
    static let metadataColumnWidth: CGFloat = 320

    // Every stage uses the same panel size.
    private let panelWidth: CGFloat = 640

    var body: some View {
        ZStack {
            // Dimming scrim; blocks interaction with the editor underneath. A scrim tap intentionally does nothing, so the flow is dismissed only through the explicit Cancel button.
            // Instant: the identity transition keeps the dimming from scaling in/out with the panel.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.identity)

            GeometryReader { geo in
                panel
                    .frame(
                        width: min(geo.size.width - 80, panelWidth),
                        height: min(geo.size.height - 80, 640)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        // Escape cancels the flow, mirroring the Cancel button. Installed here so it takes Escape ahead of the editor behind the panel (which yields while this overlay is up).
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                guard event.keyCode == 53 else { return event } // Escape
                onCancel()
                return nil
            }
        }
        .onDisappear {
            if let mon = escMonitor { NSEvent.removeMonitor(mon); escMonitor = nil }
        }
    }

    // The rounded-rectangle panel
    private var panel: some View {
        ZStack(alignment: .topLeading) {
            stageBody

            Text(stage.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(stage.headingColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            footer
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
                .foregroundColor(hovering ? appColors.uiTextBody : appColors.uiTextResting)
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
                .foregroundColor(enabled ? (hovering ? appColors.uiSurface : appColors.uiIndication) : appColors.uiTextMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(enabled && hovering ? appColors.uiIndication : appColors.uiSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(enabled ? appColors.uiIndication : appColors.uiBorder, lineWidth: 1)
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

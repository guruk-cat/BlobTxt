import SwiftUI

// The shared window shell for the File Ops overlays (Blob Metadata, Merge Blobs, Page Layout): the dimming scrim, the 640×640 centered panel with its open/close transition, and the Escape monitor. Each panel supplies only its own content and what Escape should do.
// A scrim tap intentionally does nothing, so a panel leaves only through its own buttons or Escape.
struct FileOpsOverlay<Content: View>: View {
    @EnvironmentObject var appColors: AppColors
    // Handles an Escape keypress while this overlay is the main window's content. Return true to consume it, false to let it fall through (e.g. so an alert's own Escape fires).
    let onEscape: () -> Bool
    @ViewBuilder let content: () -> Content

    @State private var escMonitor: Any?
    private let panelSize: CGFloat = 640

    var body: some View {
        ZStack {
            // Instant: the identity transition keeps the dimming from scaling in/out with the panel.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.identity)

            GeometryReader { geo in
                content()
                    .frame(
                        width: min(geo.size.width - 80, panelSize),
                        height: min(geo.size.height - 80, panelSize)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(appColors.uiBorder, lineWidth: 1)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        // Installed here so it wins over the editor behind the panel (which yields while an overlay is up).
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                guard event.keyCode == 53 else { return event } // Escape
                return onEscape() ? nil : event
            }
        }
        .onDisappear {
            if let mon = escMonitor { NSEvent.removeMonitor(mon); escMonitor = nil }
        }
    }
}

// The footer band shared by the File Ops panels: a button row over the surface, sitting at the bottom of the panel. Callers supply the buttons (leading, a Spacer, trailing).
struct FileOpsFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
    }
}

// Plain text button for the footer's leading corner (Cancel / Back / Exit).
struct SecondaryButton: View {
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

// Filled button for the footer's trailing corner (Save / Continue / Finish), with a disabled state.
struct PrimaryButton: View {
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
                        .fill(enabled && hovering ? appColors.uiIndication : appColors.uiSurface)
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

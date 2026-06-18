import SwiftUI
import AppKit

// Native viewer for image files opened in the content region. CodeMirror handles
// blobs; images are shown here as a plain NSImage, so the app needs no second JS
// environment. Closes on Escape, mirroring the editor.
struct ImageViewer: View {
    let url: URL
    let onClose: () -> Void

    // True while a file-ops overlay floats above; the Escape monitor then yields to it.
    let isModalOverlayActive: () -> Bool

    @State private var escMonitor: Any?

    var body: some View {
        ZStack {
            AppColors.shared.surface
                .ignoresSafeArea()

            if let image = NSImage(contentsOf: url) {
                // Scales down to fit the pane but never upscales past the image's
                // native size, so small images stay crisp rather than blowing up.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(24)
            } else {
                Text("Can’t display this image.")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.shared.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                guard !isModalOverlayActive() else { return event }
                if event.keyCode == 53 { // Escape
                    onClose()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escMonitor {
                NSEvent.removeMonitor(monitor)
                escMonitor = nil
            }
        }
    }
}

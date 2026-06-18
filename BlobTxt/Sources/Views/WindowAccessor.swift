import SwiftUI
import AppKit

// Reports the hosting NSWindow back to SwiftUI once the view has entered the window hierarchy. Used where a view needs its own window — to check key-window focus or to drive the window directly (close, identifier).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window isn't set until the view is mounted, so resolve on the next runloop tick.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

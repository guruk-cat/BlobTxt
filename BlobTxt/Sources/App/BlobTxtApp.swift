import SwiftUI

@main
struct BlobTxtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(AppColors.shared)
        }
        .defaultSize(width: 1300, height: 800)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    NotificationCenter.default.post(name: .showPreferences, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .saveDocument, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") {
                    NotificationCenter.default.post(name: .printDocument, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(store.activeBlobURL == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Open Project…") {
                    NotificationCenter.default.post(name: .showProjectPicker, object: nil)
                }
                Divider()
                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: .increaseFontSize, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: .decreaseFontSize, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Arrange Footnotes") {
                    NotificationCenter.default.post(name: .arrangeFootnotes, object: nil)
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Navigator") {
                    NotificationCenter.default.post(name: .toggleNavigator, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Toggle Search") {
                    NotificationCenter.default.post(name: .toggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            PaletteCommands()
        }

        // Mini view: a single editor-only window, one instance per app session. The blob it shows is driven by store.miniViewURL.
        Window("Mini View", id: "mini-view") {
            MiniView()
                .environmentObject(store)
                .environmentObject(AppColors.shared)
        }
        .defaultSize(width: 740, height: 520)

        // Dev-only live palette editor.
        Window("Palette Tool", id: "palette-tool") {
            PaletteToolView()
                .environmentObject(AppColors.shared)
        }
        .defaultSize(width: 300, height: 560)
        .windowResizability(.contentSize)
    }
}

// Cmd+Shift+P opens (and focuses) the palette tool window. Kept as a separate Commands type so it can use the openWindow environment action, which the App body cannot.
struct PaletteCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Color Palette Tool") {
                openWindow(id: "palette-tool")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cmdEMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cmd+E is consumed by NSTextView's useSelectionForFind: action before the  SwiftUI menu shortcut fires whenever a text/web view holds focus. Intercept it here at the app level so the menu item and the key always stay in sync.
        cmdEMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            else { return event }
            switch event.charactersIgnoringModifiers {
            case "e":
                // The navigator lives only in the main window, so swallow Cmd+E (rather than toggling it behind) while the mini view is key.
                if NSApp.keyWindow?.identifier?.rawValue == MiniView.windowID { return nil }
                NotificationCenter.default.post(name: .toggleNavigator, object: nil)
                return nil
            case "f":
                // Cmd+F would otherwise open WebKit's native find bar before the SwiftUI menu shortcut fires. Intercept it here to use CM6 search instead.
                NotificationCenter.default.post(name: .toggleSearch, object: nil)
                return nil
            default:
                return event
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .saveDocument, object: nil)
        // Give the async save time to complete before the process exits.
        Thread.sleep(forTimeInterval: 0.6)
    }
}

extension Notification.Name {
    static let saveDocument = Notification.Name("saveDocument")
    static let toggleNavigator = Notification.Name("toggleNavigator")
    static let toggleScratchpad = Notification.Name("toggleScratchpad")
    static let toggleOps = Notification.Name("toggleOps")
    static let toggleMetadata = Notification.Name("toggleMetadata")
    
    static let openMergeBlobs = Notification.Name("openMergeBlobs")
    static let openPageLayout = Notification.Name("openPageLayout")
    static let printDocument = Notification.Name("printDocument")

    static let toggleSearch = Notification.Name("toggleSearch")
    
    static let arrangeFootnotes = Notification.Name("arrangeFootnotes")
    static let showPreferences = Notification.Name("showPreferences")
    static let showProjectPicker = Notification.Name("showProjectPicker")
    static let settingsEscape = Notification.Name("settingsEscape")

    // Mini view: open request (object is the blob URL) and the reverse route for a cross-file link followed inside the mini view, which opens in the main window instead.
    static let openMiniView = Notification.Name("openMiniView")
    static let openInMain = Notification.Name("openInMain")

    // Font size step requests. Each mounted editor applies them only when its own window is key, so the change lands on the focused window.
    static let increaseFontSize = Notification.Name("increaseFontSize")
    static let decreaseFontSize = Notification.Name("decreaseFontSize")
}

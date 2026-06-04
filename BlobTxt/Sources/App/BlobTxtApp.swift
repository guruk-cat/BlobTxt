import SwiftUI

@main
struct BlobTxtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = ProjectStore()
    @AppStorage("fontSize") private var fontSize: Double = 16.0

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
            CommandGroup(after: .saveItem) {
                Button("Open Project…") {
                    NotificationCenter.default.post(name: .showProjectPicker, object: nil)
                }
                Button("Export to Document") {
                    NotificationCenter.default.post(name: .exportDocument, object: nil)
                }
                .disabled(store.activeEditorBlobID == nil)
                Divider()
                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Increase Font Size") {
                    if fontSize < 36 { fontSize += 1 }
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") {
                    if fontSize > 10 { fontSize -= 1 }
                }
                .keyboardShortcut("-", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Focus Mode") {
                    NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
                }
                .keyboardShortcut("m", modifiers: .command)
                Divider()
                Button("Toggle Navigator") {
                    NotificationCenter.default.post(name: .toggleNavigator, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Toggle Search") {
                    NotificationCenter.default.post(name: .toggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Toggle Outline") {
                    NotificationCenter.default.post(name: .toggleOutline, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cmdEMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cmd+E is consumed by NSTextView's useSelectionForFind: action before the
        // SwiftUI menu shortcut fires whenever a text/web view holds focus. Intercept
        // it here at the app level so the menu item and the key always stay in sync.
        cmdEMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "e" else { return event }
            NotificationCenter.default.post(name: .toggleNavigator, object: nil)
            return nil   // consume — don't let the text view see it
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
    static let exportDocument = Notification.Name("exportDocument")
    static let toggleNavigator = Notification.Name("toggleNavigator")
    static let toggleSearch = Notification.Name("toggleSearch")
    static let toggleOutline = Notification.Name("toggleOutline")
    static let toggleMetadata = Notification.Name("toggleMetadata")
    static let showPreferences = Notification.Name("showPreferences")
    static let showProjectPicker = Notification.Name("showProjectPicker")
    static let settingsEscape = Notification.Name("settingsEscape")
}

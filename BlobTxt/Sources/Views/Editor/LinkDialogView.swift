import SwiftUI
import AppKit

struct LinkDialogView: View {
    @ObservedObject var bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String

    init(bridge: EditorBridge) {
        self.bridge = bridge
        self._urlText = State(initialValue: bridge.pendingLinkHref ?? "")
    }

    private var isEditing: Bool { bridge.pendingLinkHref != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(isEditing ? "EDIT HYPERLINK" : "ADD HYPERLINK")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.shared.textHeading)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppColors.shared.textMuted)
                        .frame(width: 22, height: 22)
                        .background(AppColors.shared.surface)
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.borderCard, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
                .background(AppColors.shared.borderCard)

            VStack(alignment: .leading, spacing: 16) {
                // URL field
                HStack {
                    LinkPlainTextField(
                        placeholder: "https://",
                        text: $urlText,
                        textColor: NSColor(AppColors.shared.textBody),
                        onSubmit: confirm
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AppColors.shared.surfaceSunken)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppColors.shared.borderCard, lineWidth: 1))

                // Action buttons
                HStack(spacing: 8) {
                    if isEditing {
                        Button("Remove") {
                            bridge.unsetLink()
                            dismiss()
                        }
                        .buttonStyle(LinkDialogButtonStyle(color: AppColors.shared.textResting))
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(LinkDialogButtonStyle(color: AppColors.shared.textResting))
                    Button(isEditing ? "Update" : "Add") { confirm() }
                        .buttonStyle(LinkDialogButtonStyle(color: AppColors.shared.metaIndication))
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 380)
        .background(AppColors.shared.settingsPanel)
    }

    private func confirm() {
        var url = urlText.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") && !url.hasPrefix("mailto:") {
            url = "https://" + url
        }
        bridge.setLink(url: url)
        dismiss()
    }
}

// MARK: - Button style

private struct LinkDialogButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(configuration.isPressed ? color.opacity(0.6) : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(AppColors.shared.surface)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.borderCard, lineWidth: 1))
    }
}

// MARK: - Plain text field

private struct LinkPlainTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var textColor: NSColor
    var onSubmit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.textColor = textColor
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: (() -> Void)?
        init(text: Binding<String>) { _text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit?()
                return true
            }
            return false
        }
    }
}

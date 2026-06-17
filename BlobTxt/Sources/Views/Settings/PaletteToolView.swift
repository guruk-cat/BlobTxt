import SwiftUI
import AppKit

/// Dev-only live palette editor. Each ColorPicker is backed by the system NSColorPanel
/// (sliders, hex entry, screen eyedropper) and writes straight into AppColors, so both
/// the Swift chrome and the web editor update in real time. It never touches colors.json;
/// "Copy JSON" exports the current palette for pasting back by hand, and "Reset" reloads
/// the active palette's original values.
struct PaletteToolView: View {
    @EnvironmentObject var appColors: AppColors
    @State private var didCopy = false
    // The key whose value was just copied, for transient per-row feedback.
    @State private var copiedKey: String?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Text("PALETTE")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: appColors.resetColors) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                Button(action: copyJSON) {
                    Label(didCopy ? "Copied" : "Copy JSON", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Color groups. Keyed on reloadToken so a reset/reload re-seeds every swatch's
            // local state, while a single live edit (which bumps only paletteRevision) leaves
            // the active picker's identity — and its in-drag value — intact.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Editor", keys: AppColors.editorKeys)
                    group("UI", keys: AppColors.uiKeys)
                    group("Git", keys: AppColors.gitKeys)
                    group("Wildcard", keys: AppColors.wildcardKeys)
                }
                .padding(16)
            }
            .id(appColors.reloadToken)
        }
        .frame(width: 300, height: 560)
    }

    // A titled section of swatch rows.
    @ViewBuilder
    private func group(_ title: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(keys, id: \.self) { key in
                SwatchRow(key: key, copiedKey: $copiedKey, onCopy: copyValue)
            }
        }
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appColors.exportJSON(), forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }

    private func copyValue(_ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appColors.valueString(forKey: key), forType: .string)
        copiedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedKey == key { copiedKey = nil }
        }
    }
}

/// One palette key: native color well, its colors.json name, and a copy-value button.
/// The picker drives a local @State color and pushes outward to AppColors; it never reads
/// the discretized stored value back, which would otherwise fight the wheel/slider mid-drag.
private struct SwatchRow: View {
    let key: String
    @Binding var copiedKey: String?
    let onCopy: (String) -> Void

    @EnvironmentObject var appColors: AppColors
    @State private var color: Color

    init(key: String, copiedKey: Binding<String?>, onCopy: @escaping (String) -> Void) {
        self.key = key
        self._copiedKey = copiedKey
        self.onCopy = onCopy
        self._color = State(initialValue: AppColors.shared.color(forKey: key))
    }

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: color) { appColors.setColor($0, forKey: key) }
            Text(key)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            // Copies this key's RGB value, e.g. "[48, 42, 38]".
            Button(action: { onCopy(key) }) {
                Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy value")
        }
    }
}

#Preview {
    PaletteToolView()
        .environmentObject(AppColors.shared)
}

import SwiftUI
import AppKit

/// Dev-only live palette editor. Each ColorPicker is backed by the system NSColorPanel
/// (sliders, hex entry, screen eyedropper) and writes straight into AppColors, so both
/// the Swift chrome and the web editor update in real time. It never touches colors.json;
/// "Copy JSON" exports the current palette for pasting back by hand.
struct PaletteToolView: View {
    @EnvironmentObject var appColors: AppColors
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("PALETTE")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: copyJSON) {
                    Label(didCopy ? "Copied" : "Copy JSON", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Color groups
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Editor", keys: AppColors.editorKeys)
                    group("UI", keys: AppColors.uiKeys)
                    group("Git", keys: AppColors.gitKeys)
                    group("Wildcard", keys: AppColors.wildcardKeys)
                }
                .padding(16)
            }
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
                row(key)
            }
        }
    }

    // One key: native color well + its colors.json name.
    private func row(_ key: String) -> some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: binding(for: key), supportsOpacity: false)
                .labelsHidden()
            Text(key)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
        }
    }

    // Reads/writes the live value through AppColors so edits propagate everywhere.
    private func binding(for key: String) -> Binding<Color> {
        Binding(
            get: { appColors.color(forKey: key) },
            set: { appColors.setColor($0, forKey: key) }
        )
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appColors.exportJSON(), forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }
}

#Preview {
    PaletteToolView()
        .environmentObject(AppColors.shared)
}

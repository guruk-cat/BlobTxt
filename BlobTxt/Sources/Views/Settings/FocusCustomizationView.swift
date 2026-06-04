import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FocusCustomizationView: View {
    var onBack: () -> Void

    @EnvironmentObject var appColors: AppColors
    @AppStorage("defaultFocusMode") private var defaultFocusMode: Bool = false
    @AppStorage("focusFloating") private var focusFloating: Bool = true
    @AppStorage("focusWallpaperPath") private var focusWallpaperPath: String = ""
    @AppStorage("focusDimness") private var focusDimness: Double = 0.5
    @AppStorage("focusBlur") private var focusBlur: Double = 0.0

    private var wallpaperFilename: String {
        focusWallpaperPath.isEmpty ? "None" : URL(fileURLWithPath: focusWallpaperPath).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                        Text("Back")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(AppColors.shared.textBody)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text("FOCUS MODE")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.shared.textHeading)

                Spacer()

                // Balance the back button width
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
                .background(AppColors.shared.borderCard)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Note
                    settingsSection {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.shared.metaIndication)
                                .padding(.top, 1)
                            Text("These settings take effect only when BlobTxt is in full-screen mode.")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.shared.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    // Appearance
                    settingsSection {
                        settingsRow("Enable in full screen by default") {
                            Toggle("", isOn: $defaultFocusMode)
                                .toggleStyle(.switch)
                                .tint(AppColors.shared.metaIndication)
                                .controlSize(.mini)
                        }
                        Divider().padding(.leading, 12)
                        settingsRow("Floating editor window") {
                            Toggle("", isOn: $focusFloating)
                                .toggleStyle(.switch)
                                .tint(AppColors.shared.metaIndication)
                                .controlSize(.mini)
                                .onChange(of: focusFloating) { _ in postChanged() }
                        }
                    }

                    // Wallpaper
                    settingsSection {
                        // Image picker row
                        HStack {
                            Text("Image")
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.shared.textResting)
                            Spacer()
                            Text(wallpaperFilename)
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.shared.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 120, alignment: .trailing)
                            if !focusWallpaperPath.isEmpty {
                                Button(action: clearWallpaper) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(AppColors.shared.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            Button("Select") { openWallpaperPicker() }
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.shared.textResting)
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)

                        Divider().padding(.leading, 12)

                        // Dimness slider
                        settingsSliderRow(
                            label: "Dimness",
                            value: $focusDimness,
                            range: 0...1,
                            displayValue: String(format: "%.0f%%", focusDimness * 100)
                        ) { postChanged() }

                        Divider().padding(.leading, 12)

                        // Blur slider
                        settingsSliderRow(
                            label: "Blur",
                            value: $focusBlur,
                            range: 0...20,
                            displayValue: String(format: "%.0fpx", focusBlur)
                        ) { postChanged() }
                    }
                }
                .padding(20)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 380, height: 480)
        .background(AppColors.shared.settingsPanel)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(spacing: 0) { content() }
        }
        .groupBoxStyle(FocusBoxStyle(background: appColors.settingsBox))
    }

    @ViewBuilder
    private func settingsRow<Content: View>(_ label: String, @ViewBuilder control: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(AppColors.shared.textResting)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder
    private func settingsSliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String,
        onEditEnd: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.shared.textResting)
                Spacer()
                Text(displayValue)
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.shared.textMuted)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Slider(value: value, in: range)
                .tint(AppColors.shared.metaIndication)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .onChange(of: value.wrappedValue) { _ in onEditEnd() }
        }
    }

    // MARK: - Wallpaper management

    private func openWallpaperPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .gif, .tiff, .bmp, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            saveWallpaper(from: url)
        }
    }

    private func saveWallpaper(from sourceURL: URL) {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("BlobTxt", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("wallpaper.\(ext)")
        // Remove previous copy if present
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: sourceURL, to: dest)
            focusWallpaperPath = dest.path
            postChanged()
        } catch {
            print("[FocusCustomizationView] Failed to copy wallpaper: \(error)")
        }
    }

    private func clearWallpaper() {
        if !focusWallpaperPath.isEmpty {
            try? FileManager.default.removeItem(atPath: focusWallpaperPath)
        }
        focusWallpaperPath = ""
        postChanged()
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .focusCustomizationChanged, object: nil)
    }
}

private struct FocusBoxStyle: GroupBoxStyle {
    let background: Color
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) { configuration.content }
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    FocusCustomizationView(onBack: {})
        .environmentObject(AppColors.shared)
}

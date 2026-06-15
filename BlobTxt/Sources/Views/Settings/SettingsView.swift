import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appColors: AppColors
    @Environment(\.dismiss) private var dismiss

    // Defaults
    @AppStorage("colorPalette") private var colorPalette: String = "stone"
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("autoScroll") private var autoScroll: String = "centered"
    @AppStorage("lightPalette") private var lightPalette: String = "paper"
    @AppStorage("lastDarkPalette") private var lastDarkPalette: String = "stone"
    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @State private var escMonitor: Any?

    private var lightPaletteOptions: [String] {
        appColors.palettes(ofType: "light")
    }

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.shared.uiTextHeading)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppColors.shared.uiTextMuted)
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

            // Settings form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // MARK: Font
                    settingsSection {
                        settingsRow("Font family") {
                            Picker("", selection: $fontFamily) {
                                Text("Menlo").tag("Menlo")
                                Text("Palatino").tag("Palatino")
                            }
                            .pickerStyle(.menu)
                        }
                        Divider().padding(.leading, 12)
                        settingsRow("Font size") {
                            HStack(spacing: 6) {
                                Button(action: { if fontSize > 10 { fontSize -= 1 } }) {
                                    Image(systemName: "minus")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(AppColors.shared.uiTextResting)
                                        .frame(width: 22, height: 22)
                                        .background(AppColors.shared.settingsPanel)
                                        .cornerRadius(5)
                                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.borderCard, lineWidth: 1))
                                }
                                .buttonStyle(.plain)

                                Text("\(Int(fontSize))pt")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.shared.uiTextResting)
                                    .frame(width: 36, alignment: .center)

                                Button(action: { if fontSize < 36 { fontSize += 1 } }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(AppColors.shared.uiTextResting)
                                        .frame(width: 22, height: 22)
                                        .background(AppColors.shared.settingsPanel)
                                        .cornerRadius(5)
                                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.borderCard, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // MARK: Editor behavior
                    settingsSection{
                        settingsRow("Auto-scroll when hitting bottom") {
                            Toggle("", isOn: Binding(
                                get: { autoScroll == "centered" },
                                set: { autoScroll = $0 ? "centered" : "regular" }
                            ))
                            .toggleStyle(.switch)
                            .tint(AppColors.shared.metaIndication)
                            .controlSize(.mini)
                        }
                    }
                    
                    // MARK: Colors
                    settingsSection {
                        settingsRow("Follow macOS appearance") {
                            Toggle("", isOn: $followSystemAppearance)
                                .toggleStyle(.switch)
                                .tint(AppColors.shared.metaIndication)
                                .controlSize(.mini)
                                .onChange(of: followSystemAppearance) { isOn in
                                    if isOn {
                                        autoCorrectPalettesForSystem()
                                        let dark = UserDefaults(suiteName: "Apple Global Domain")?
                                            .string(forKey: "AppleInterfaceStyle") == "Dark"
                                        appColors.applySystemAppearance(dark: dark)
                                    } else {
                                        appColors.reloadManualPalette()
                                    }
                                }
                        }
                        Divider().padding(.leading, 12)
                        if followSystemAppearance {
                            settingsRow("Dark palette") {
                                Picker("", selection: $lastDarkPalette) {
                                    ForEach(appColors.palettes(ofType: "dark"), id: \.self) { palette in
                                        Text(palette.replacingOccurrences(of: "_", with: " ").capitalized).tag(palette)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: lastDarkPalette) { newPalette in
                                    if appColors.isDark { appColors.loadColors(palette: newPalette) }
                                }
                            }
                            Divider().padding(.leading, 12)
                            settingsRow("Light palette") {
                                Picker("", selection: $lightPalette) {
                                    ForEach(lightPaletteOptions, id: \.self) { palette in
                                        Text(palette.replacingOccurrences(of: "_", with: " ").capitalized).tag(palette)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: lightPalette) { newPalette in
                                    if !appColors.isDark { appColors.loadColors(palette: newPalette) }
                                }
                            }
                        } else {
                            settingsRow("Color palette") {
                                Picker("", selection: $colorPalette) {
                                    ForEach(appColors.availablePalettes, id: \.self) { palette in
                                        Text(palette.replacingOccurrences(of: "_", with: " ").capitalized).tag(palette)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: colorPalette) { newPalette in
                                    appColors.loadColors(palette: newPalette)
                                    if appColors.paletteTypes[newPalette] == "dark" {
                                        lastDarkPalette = newPalette
                                    }
                                }
                            }
                        }
                    }

                }
                .padding(20)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 380, height: 480)
        .background(AppColors.shared.settingsPanel)
        } // ZStack
        .frame(width: 380, height: 480)
        .onReceive(NotificationCenter.default.publisher(for: .settingsEscape)) { _ in
            dismiss()
        }
        .onAppear {
            // Register a monitor that fires the settingsEscape notification when ESC is pressed
            // while this sheet window is key (not the main editor window).
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                guard let keyWin = NSApp.keyWindow, keyWin !== NSApp.mainWindow else { return event }
                NotificationCenter.default.post(name: .settingsEscape, object: nil)
                return nil
            }
        }
        .onDisappear {
            if let mon = escMonitor { NSEvent.removeMonitor(mon); escMonitor = nil }
        }
        .task {
            if lastDarkPalette.isEmpty || appColors.paletteTypes[lastDarkPalette] != "dark" {
                lastDarkPalette = appColors.paletteTypes[colorPalette] == "dark"
                    ? colorPalette
                    : (appColors.palettes(ofType: "dark").first ?? "")
            }
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func settingsSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                content()
            }
        }
        .groupBoxStyle(SurfaceGroupBoxStyle(background: appColors.settingsBox))
    }

    @ViewBuilder
    private func settingsRow<Content: View>(_ label: String, @ViewBuilder control: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(AppColors.shared.uiTextResting)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func autoCorrectPalettesForSystem() {
        let darkList = appColors.palettes(ofType: "dark")
        if !darkList.contains(lastDarkPalette) {
            lastDarkPalette = darkList.first ?? ""
        }
        let lightList = appColors.palettes(ofType: "light")
        if !lightList.contains(lightPalette) {
            lightPalette = lightList.first ?? ""
        }
    }

}

private struct SurfaceGroupBoxStyle: GroupBoxStyle {
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            configuration.content
        }
        .frame(maxWidth: .infinity)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppColors.shared)
}

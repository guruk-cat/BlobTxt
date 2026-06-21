import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appColors: AppColors
    @ObservedObject private var layoutStore = LayoutStore.shared
    @Environment(\.dismiss) private var dismiss

    // Defaults
    @AppStorage("colorPalette") private var colorPalette: String = "stone"
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("miniFontSize") private var miniFontSize: Double = 14.0
    @AppStorage("autoScroll") private var autoScroll: String = "centered"
    @AppStorage("lightPalette") private var lightPalette: String = "paperback"
    @AppStorage("darkPalette") private var darkPalette: String = "stone"
    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @State private var escMonitor: Any?
    @State private var closeHovered = false

    private var lightPaletteOptions: [String] {
        appColors.palettes(ofType: "light")
    }
    
    private var uiColorScheme: ColorScheme {
        appColors.isUIDark ? .dark : .light
    }

    var body: some View {
        ZStack {
        // MARK: Settings form
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    settingsSection("Editor font") {
                        settingsRow("Font family") {
                            Picker("", selection: $fontFamily) {
                                Text("Menlo").tag("Menlo")
                                Text("Palatino").tag("Palatino")
                            }
                            .pickerStyle(.menu)
                            .colorScheme(uiColorScheme)
                        }
                        rowDivider()
                        settingsRow("Font size") { fontSizeStepper($fontSize) }
                        rowDivider()
                        settingsRow("Mini view font size") { fontSizeStepper($miniFontSize) }
                    }
                    
                    settingsSection("Editor behavior") {
                        settingsRow("Auto-scroll when hitting bottom") {
                            Toggle("", isOn: Binding(
                                get: { autoScroll == "centered" },
                                set: { autoScroll = $0 ? "centered" : "regular" }
                            ))
                            .toggleStyle(.switch)
                            .tint(AppColors.shared.uiIndication)
                            .controlSize(.mini)
                        }
                    }
                    
                    settingsSection("Colors") {
                        settingsRow("Follow macOS appearance") {
                            Toggle("", isOn: $followSystemAppearance)
                                .toggleStyle(.switch)
                                .tint(AppColors.shared.uiIndication)
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
                        rowDivider()
                        if followSystemAppearance {
                            settingsRow("Dark palette") {
                                Picker("", selection: $darkPalette) {
                                    ForEach(appColors.palettes(ofType: "dark"), id: \.self) { palette in
                                        Text(palette.replacingOccurrences(of: "_", with: " ").capitalized).tag(palette)
                                    }
                                }
                                .pickerStyle(.menu)
                                .colorScheme(uiColorScheme)
                                .onChange(of: darkPalette) { newPalette in
                                    if appColors.isDark { appColors.loadColors(palette: newPalette) }
                                }
                            }
                            rowDivider()
                            settingsRow("Light palette") {
                                Picker("", selection: $lightPalette) {
                                    ForEach(lightPaletteOptions, id: \.self) { palette in
                                        Text(palette.replacingOccurrences(of: "_", with: " ").capitalized).tag(palette)
                                    }
                                }
                                .pickerStyle(.menu)
                                .colorScheme(uiColorScheme)
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
                                .colorScheme(uiColorScheme)
                                .onChange(of: colorPalette) { newPalette in
                                    appColors.loadColors(palette: newPalette)
                                    if appColors.paletteTypes[newPalette] == "dark" {
                                        darkPalette = newPalette
                                    }
                                }
                            }
                        }
                    }

                    settingsSection("File operations") {
                        settingsRow("Go-to print profile") {
                            Picker("", selection: Binding(
                                get: { layoutStore.goToProfileID },
                                set: { layoutStore.setGoTo($0) }
                            )) {
                                ForEach(layoutStore.allProfiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .colorScheme(uiColorScheme)
                        }
                    }

                }
                .padding(20)
        }
        .background(AppColors.shared.uiSurface)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.shared.uiTextHeading)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(closeHovered ? AppColors.shared.uiTextBody : AppColors.shared.uiTextMuted)
                        .frame(width: 22, height: 22)
                        .background(AppColors.shared.uiSurface)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
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
            if darkPalette.isEmpty || appColors.paletteTypes[darkPalette] != "dark" {
                darkPalette = appColors.paletteTypes[colorPalette] == "dark"
                    ? colorPalette
                    : (appColors.palettes(ofType: "dark").first ?? "")
            }
        }
    }

    // MARK: Layout helpers

    @ViewBuilder
    private func settingsSection<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                content()
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.shared.uiTextBody)
        }
        .groupBoxStyle(SurfaceGroupBoxStyle(background: appColors.uiSunken))
    }

    // A minus/value/plus stepper for a font size, clamped to 10–36pt.
    private func fontSizeStepper(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Button(action: { if value.wrappedValue > 10 { value.wrappedValue -= 1 } }) {
                stepperGlyph("minus")
            }
            .buttonStyle(.plain)

            Text("\(Int(value.wrappedValue))pt")
                .font(.system(size: 13))
                .foregroundColor(AppColors.shared.uiTextResting)
                .frame(width: 36, alignment: .center)

            Button(action: { if value.wrappedValue < 36 { value.wrappedValue += 1 } }) {
                stepperGlyph("plus")
            }
            .buttonStyle(.plain)
        }
    }

    private func stepperGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(AppColors.shared.uiTextResting)
            .frame(width: 22, height: 22)
            .background(AppColors.shared.uiSurface)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.uiBorder, lineWidth: 1))
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
    
    private func rowDivider() -> some View {
        Divider().padding(.horizontal, 12)
    }

    private func autoCorrectPalettesForSystem() {
        let darkList = appColors.palettes(ofType: "dark")
        if !darkList.contains(darkPalette) {
            darkPalette = darkList.first ?? ""
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
        VStack(alignment: .leading, spacing: 0) {
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

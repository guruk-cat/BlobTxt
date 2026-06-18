import SwiftUI

// The Page Layout panel's right column: the editing form for one profile. Every control writes
// directly into the bound `draft`; the panel decides when to commit it. Shown disabled for the
// read-only default profile. Numeric fields buffer their text locally and push validated values into
// the draft, so a value is left unset (nil = "let pandoc/weasyprint decide") when the field is empty.
struct LayoutDetailPane: View {
    @EnvironmentObject var appColors: AppColors
    @Binding var draft: LayoutProfile
    let readOnly: Bool

    // Local text mirrors for the validated numeric fields, seeded from the draft on appear.
    @State private var fontSizeStr = ""
    @State private var marginTopStr = ""
    @State private var marginBottomStr = ""
    @State private var marginSideStr = ""

    @FocusState private var nameFocused: Bool

    private var uiColorScheme: ColorScheme { appColors.isUIDark ? .dark : .light }

    // A curated set of widely-installed families rather than the full system catalog: enumerating all
    // fonts is slow, and export (pandoc + weasyprint) can only render a font present on the system.
    private let fontFamilies = [
        "Times New Roman", "Georgia", "Helvetica", "Arial",
        "Palatino", "Garamond", "Courier New", "Menlo",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if readOnly {
                    Text("The default profile uses pandoc + weasyprint defaults and can't be edited. Add or duplicate a profile to customize.")
                        .font(.system(size: 12))
                        .foregroundColor(appColors.uiTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                nameSection
                stylesSection
                pageSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(readOnly)
        .onAppear(perform: seedFields)
    }

    // MARK: - Name

    private var nameSection: some View {
        groupBox {
            row("Name") {
                TextField("", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(appColors.uiTextBody)
                    .multilineTextAlignment(.trailing)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
            }
        }
    }

    // MARK: - Styles

    private var stylesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("STYLES")

            groupBox {
                row("Font family") {
                    Picker("", selection: $draft.bodyFontFamily) {
                        Text("Default").tag(String?.none)
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family).tag(String?.some(family))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .colorScheme(uiColorScheme)
                }
                rowDivider
                row("Font size") {
                    numericField($fontSizeStr, unit: "pt") { draft.bodyFontSizePt = $0 }
                }
                rowDivider
                row("Alignment") {
                    Picker("", selection: $draft.bodyAlignment) {
                        Text("Default").tag(LayoutProfile.TextAlignment?.none)
                        ForEach(LayoutProfile.TextAlignment.allCases, id: \.self) { option in
                            Text(option.label).tag(LayoutProfile.TextAlignment?.some(option))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .colorScheme(uiColorScheme)
                }
                rowDivider
                row("Auto-hyphenation") {
                    Toggle("", isOn: $draft.hyphenation)
                        .toggleStyle(.switch)
                        .tint(appColors.uiIndication)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }

            groupBox {
                HStack {
                    Text("Headings controls yet to be implemented.")
                        .font(.system(size: 12))
                        .foregroundColor(appColors.uiTextMuted)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
            }
        }
    }

    // MARK: - Page

    private var pageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("PAGE")

            groupBox {
                row("Paper size") {
                    Picker("", selection: $draft.paperSize) {
                        Text("Default").tag(LayoutProfile.PaperSize?.none)
                        ForEach(LayoutProfile.PaperSize.allCases, id: \.self) { option in
                            Text(option.label).tag(LayoutProfile.PaperSize?.some(option))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .colorScheme(uiColorScheme)
                }
                rowDivider
                row("Orientation") {
                    Picker("", selection: $draft.orientation) {
                        Text("Default").tag(LayoutProfile.Orientation?.none)
                        ForEach(LayoutProfile.Orientation.allCases, id: \.self) { option in
                            Text(option.label).tag(LayoutProfile.Orientation?.some(option))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .colorScheme(uiColorScheme)
                }
            }

            groupBox {
                row("Top margin") {
                    numericField($marginTopStr, unit: "in") { draft.marginTopIn = $0 }
                }
                rowDivider
                row("Bottom margin") {
                    numericField($marginBottomStr, unit: "in") { draft.marginBottomIn = $0 }
                }
                rowDivider
                row("Side margins") {
                    numericField($marginSideStr, unit: "in") { draft.marginSideIn = $0 }
                }
            }

            groupBox {
                row("Page numbers") {
                    Toggle("", isOn: $draft.pageNumbers)
                        .toggleStyle(.switch)
                        .tint(appColors.uiIndication)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - Field building blocks

    // A small right-aligned text field plus a unit suffix. Filters to a decimal and writes the parsed
    // value (nil when empty) back through `commit`.
    private func numericField(_ text: Binding<String>, unit: String, commit: @escaping (Double?) -> Void) -> some View {
        HStack(spacing: 4) {
            TextField("Default", text: Binding(
                get: { text.wrappedValue },
                set: { raw in
                    let clean = Self.sanitizeDecimal(raw)
                    text.wrappedValue = clean
                    commit(clean.isEmpty ? nil : Double(clean))
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(appColors.uiTextBody)
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            Text(unit)
                .font(.system(size: 12))
                .foregroundColor(appColors.uiTextResting)
        }
    }

    // Keeps digits and a single decimal point.
    private static func sanitizeDecimal(_ raw: String) -> String {
        var seenDot = false
        var out = ""
        for ch in raw {
            if ch.isNumber {
                out.append(ch)
            } else if ch == ".", !seenDot {
                seenDot = true
                out.append(ch)
            }
        }
        return out
    }

    private func seedFields() {
        fontSizeStr = draft.bodyFontSizePt.map(Self.format) ?? ""
        marginTopStr = draft.marginTopIn.map(Self.format) ?? ""
        marginBottomStr = draft.marginBottomIn.map(Self.format) ?? ""
        marginSideStr = draft.marginSideIn.map(Self.format) ?? ""
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - Layout helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(appColors.uiIndication)
    }

    @ViewBuilder
    private func groupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(spacing: 0) { content() }
        }
        .groupBoxStyle(LayoutGroupBoxStyle(background: appColors.uiSunken, border: appColors.uiBorder))
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder control: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(appColors.uiTextResting)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 12)
    }
}

private struct LayoutGroupBoxStyle: GroupBoxStyle {
    let background: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) { configuration.content }
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
    }
}

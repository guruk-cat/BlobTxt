import SwiftUI

// The second MB stage. Left pane (`chromePanel`): heading adjustment controls, grouped per blob with a
// merge-wide section on top. Right pane (`surface`): a live preview of the final merged headings in
// order, rendered roughly like the editor.
//
// The preview is exactly the heading list `MergeEngine` will emit when the file is written, so what is
// shown here is what gets saved.
struct MergeHeadingsStage: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @ObservedObject var session: MergeSession

    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"

    // Each selected blob's body, cached on appear. The selection is fixed while this stage is shown, so
    // the bodies never change here — only the config does, and the preview recomputes from these.
    @State private var blobBodies: [URL: String] = [:]

    private let topInset: CGFloat = 44
    private let bottomInset: CGFloat = 56

    // Shows an adjustment with an explicit sign, so promote (positive) and demote (negative) read clearly.
    private let signed: (Int) -> String = { $0 > 0 ? "+\($0)" : "\($0)" }

    // Rendered at the base editor size (bold still marks them as headings).
    private var headingSize: CGFloat { CGFloat(fontSize) }
    private var resolvedFamily: String { fontFamily.isEmpty ? "Menlo" : fontFamily }

    var body: some View {
        HStack(spacing: 0) {
            adjustmentsPane
                .frame(maxWidth: MergeBlobsPanel.headingsColumnWidth, maxHeight: .infinity)
                .background(appColors.chromePanel)
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appColors.surface)
        }
        .onAppear { rebuild() }
    }

    // MARK: - Left pane: adjustments

    private var adjustmentsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                mergeWideCard
                ForEach(session.selected, id: \.self) { url in
                    blobCard(url)
                }
            }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Merge-wide adjustments, applied to all blobs at once.
    private var mergeWideCard: some View {
        let wide = wideBinding
        return card {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("ALL BLOBS")
                StepperControl(label: "Adjust headings by", value: wide.adjustAllBy, range: -5...5, format: signed)
                ToggleRow(label: "Renumber headings", isOn: wide.renumber)
                ToggleRow(label: "Number H1 headings", isOn: wide.numberH1)
                    .disabled(!session.headingConfig.renumber)
                    .opacity(session.headingConfig.renumber ? 1 : 0.4)
            }
        }
    }

    // One blob's adjustments. Shows the highest heading level (and how many share it) when the blob has
    // headings, or an "add a heading" affordance when it has none.
    private func blobCard(_ url: URL) -> some View {
        let cfg = configBinding(for: url)
        let raw = MergeEngine.headings(in: blobBodies[url] ?? "")
        let top = topLevel(of: raw)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(MergeSession.displayName(for: url))

                if let top = top {
                    Text(topLevelDescription(top))
                        .font(.system(size: 11))
                        .foregroundColor(appColors.uiTextMuted)
                    StepperControl(label: "Adjust headings by", value: cfg.adjustBy, range: -5...5, format: signed)
                } else {
                    Text("No headings.")
                        .font(.system(size: 11))
                        .foregroundColor(appColors.uiTextMuted)
                    ToggleRow(label: "Add a heading", isOn: cfg.addHeading)
                    if cfg.addHeading.wrappedValue {
                        addHeadingFields(cfg)
                    }
                }
            }
        }
    }

    // Content + level controls for a synthesized heading on a blob that has none.
    private func addHeadingFields(_ cfg: Binding<BlobHeadingConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Heading text", text: cfg.addedHeadingText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(appColors.uiTextBody)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(appColors.chromeSunken))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(appColors.borderCard, lineWidth: 1))
            StepperControl(label: "Level", value: cfg.addedHeadingLevel, range: 1...6) { "H\($0)" }
        }
        .padding(.leading, 2)
    }

    private func cardHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(appColors.uiTextHeading)
            .lineLimit(1)
    }

    // A grouped block on the panel surface.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(appColors.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(appColors.borderCard, lineWidth: 1))
    }

    // MARK: - Right pane: heading preview

    private var previewPane: some View {
        let preview = MergeEngine.merge(session: session) { blobBodies[$0] }.headings
        return ScrollView {
            VStack(alignment: .leading, spacing: headingSize * 0.8) {
                if preview.isEmpty {
                    Text("No headings to merge.")
                        .font(.system(size: 13))
                        .foregroundColor(appColors.uiTextMuted)
                } else {
                    ForEach(preview.indices, id: \.self) { i in
                        Text(markdownLine(for: preview[i]))
                            .font(.custom(resolvedFamily, size: headingSize).weight(.bold))
                            .foregroundColor(appColors.uiTextHeading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdownLine(for heading: MergedHeading) -> String {
        String(repeating: "#", count: heading.level) + " " + heading.text
    }

    // MARK: - Bindings

    private var wideBinding: Binding<MergeWideHeadingConfig> {
        Binding(get: { session.headingConfig }, set: { session.headingConfig = $0 })
    }

    private func configBinding(for url: URL) -> Binding<BlobHeadingConfig> {
        Binding(get: { session.blobConfig(for: url) }, set: { session.setBlobConfig($0, for: url) })
    }

    // MARK: - Stats

    // The highest (most prominent, lowest-numbered) heading level present, and how many headings share it.
    private func topLevel(of headings: [MergedHeading]) -> (level: Int, count: Int)? {
        guard let level = headings.map(\.level).min() else { return nil }
        return (level, headings.filter { $0.level == level }.count)
    }

    private func topLevelDescription(_ top: (level: Int, count: Int)) -> String {
        let level = "Highest: H\(top.level)"
        return top.count > 1 ? "\(level) · \(top.count) at this level" : level
    }

    // MARK: - Caching

    private func rebuild() {
        var map: [URL: String] = [:]
        for url in session.selected {
            map[url] = store.readBody(url: url) ?? ""
        }
        blobBodies = map
    }
}

// MARK: - Controls

// A compact "−  value  +" stepper styled for the panel, with an optional value formatter.
private struct StepperControl: View {
    @EnvironmentObject var appColors: AppColors
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(appColors.uiTextResting)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                stepButton("minus", enabled: value > range.lowerBound) {
                    if value > range.lowerBound { value -= 1 }
                }
                Text(format(value))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(appColors.uiTextBody)
                    .frame(minWidth: 26)
                stepButton("plus", enabled: value < range.upperBound) {
                    if value < range.upperBound { value += 1 }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(appColors.chromeSunken))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(appColors.borderCard, lineWidth: 1))
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(enabled ? appColors.uiTextResting : appColors.uiTextMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// A labeled switch styled to the accent color, with the switch pushed to the trailing edge of the row.
private struct ToggleRow: View {
    @EnvironmentObject var appColors: AppColors
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(appColors.uiTextResting)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(appColors.metaIndication)
        }
    }
}

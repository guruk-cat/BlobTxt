import SwiftUI

// A heading pulled from a selected blob, in merge order.
struct MergedHeading: Identifiable {
    let id = UUID()
    let level: Int     // 1...6, the number of leading `#`
    let text: String   // heading text, marks stripped
}

// The second MB stage. Left pane (`chromePanel`): heading adjustment controls, grouped per blob with
// a merge-wide section on top. Right pane (`surface`): a live preview of the final merged headings in
// order, with every adjustment applied, rendered roughly like the editor (its font, bold, `textHeading`,
// the literal `#` marks kept, all levels at the same size).
struct MergeHeadingsStage: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @ObservedObject var session: MergeSession

    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"

    // Each selected blob's headings as found on disk, keyed by URL. Rebuilt on appear; the selection
    // is fixed while this stage is shown, so the raw headings never change here — only the config does.
    @State private var blobHeadings: [URL: [MergedHeading]] = [:]

    private let topInset: CGFloat = 44
    private let bottomInset: CGFloat = 56

    // Rendered at the base editor size (bold still marks them as headings).
    private var headingSize: CGFloat { CGFloat(fontSize) }
    private var resolvedFamily: String { fontFamily.isEmpty ? "Menlo" : fontFamily }

    var body: some View {
        HStack(spacing: 0) {
            adjustmentsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                StepperControl(label: "Demote all headings by", value: wide.demoteAllBy, range: 0...5)
                ToggleRow(label: "Renumber headings", isOn: wide.renumber)
                ToggleRow(label: "Number top-level (H1) headings", isOn: wide.numberH1)
                    .disabled(!session.headingConfig.renumber)
                    .opacity(session.headingConfig.renumber ? 1 : 0.4)
            }
        }
    }

    // One blob's adjustments. Shows the highest heading level (and how many share it) when the blob has
    // headings, or an "add a heading" affordance when it has none.
    private func blobCard(_ url: URL) -> some View {
        let cfg = configBinding(for: url)
        let raw = blobHeadings[url] ?? []
        let top = topLevel(of: raw)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(MergeSession.displayName(for: url))

                if let top = top {
                    Text(topLevelDescription(top))
                        .font(.system(size: 11))
                        .foregroundColor(appColors.textMuted)
                    StepperControl(label: "Demote by", value: cfg.demoteBy, range: 0...5)
                } else {
                    Text("No headings.")
                        .font(.system(size: 11))
                        .foregroundColor(appColors.textMuted)
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
                .foregroundColor(appColors.textBody)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(appColors.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(appColors.borderCard, lineWidth: 1))
            StepperControl(label: "Level", value: cfg.addedHeadingLevel, range: 1...6) { "H\($0)" }
        }
        .padding(.leading, 2)
    }

    private func cardHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(appColors.textHeading)
            .lineLimit(1)
    }

    // A grouped block on the panel surface.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(appColors.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(appColors.borderCard, lineWidth: 1))
    }

    // MARK: - Right pane: heading preview

    private var previewPane: some View {
        let preview = mergedPreview()
        return ScrollView {
            VStack(alignment: .leading, spacing: headingSize * 0.8) {
                if preview.isEmpty {
                    Text("No headings to merge.")
                        .font(.system(size: 13))
                        .foregroundColor(appColors.textMuted)
                } else {
                    ForEach(preview.indices, id: \.self) { i in
                        Text(markdownLine(for: preview[i]))
                            .font(.custom(resolvedFamily, size: headingSize).weight(.bold))
                            .foregroundColor(appColors.textHeading)
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

    // MARK: - Transformation

    // The merged heading list with every adjustment applied, in selection order. This is what the
    // preview renders and what the final merge will eventually use.
    private func mergedPreview() -> [MergedHeading] {
        let wide = session.headingConfig
        var out: [MergedHeading] = []
        for url in session.selected {
            let cfg = session.blobConfig(for: url)
            var raw = blobHeadings[url] ?? []
            // A blob with no headings contributes its synthesized heading, if one was provided. Its
            // text is normalized the same way extracted headings are, so any number the user typed is
            // managed by the merge rather than baked in.
            let added = Self.strippingLeadingNumber(cfg.addedHeadingText.trimmingCharacters(in: .whitespaces))
            if raw.isEmpty, cfg.addHeading, !added.isEmpty {
                raw = [MergedHeading(level: cfg.addedHeadingLevel, text: added)]
            }
            for h in raw {
                let level = min(6, h.level + cfg.demoteBy + wide.demoteAllBy)
                out.append(MergedHeading(level: level, text: h.text))
            }
        }
        return wide.renumber ? Self.numbered(out, numberH1: wide.numberH1) : out
    }

    // Prepends a nested number to each heading, counting continuously across the whole merge. The
    // numbering anchors at H1 when `numberH1` is true, otherwise at H2 (H1s stay unnumbered).
    static func numbered(_ headings: [MergedHeading], numberH1: Bool) -> [MergedHeading] {
        let baseLevel = numberH1 ? 1 : 2
        var counters: [Int] = []   // counters[d] is the current count at numbering depth d (0-based)
        return headings.map { h in
            guard h.level >= baseLevel else { return h }   // above the numbered range: left as-is
            let depth = h.level - baseLevel
            if depth < counters.count {
                counters[depth] += 1
                counters.removeSubrange((depth + 1)..<counters.count)
            } else {
                while counters.count < depth { counters.append(1) }   // pad any skipped levels
                counters.append(1)
            }
            let number = counters.map(String.init).joined(separator: ".") + "."
            return MergedHeading(level: h.level, text: "\(number) \(h.text)")
        }
    }

    // Strips a leading manual number from heading text — nested dotted forms ("1.", "1.1.", "2.3.1")
    // and simple terminated forms ("2:", "1)") — together with the whitespace after it, returning the
    // bare title. Headings are stored number-free so the level is the single source of truth; numbers
    // are reapplied only by `numbered()`. Text without such a prefix is returned unchanged.
    static func strippingLeadingNumber(_ text: String) -> String {
        var s = Substring(text)
        guard s.first?.isNumber == true else { return text }
        // A nested dotted number: digit runs separated by ".", with an optional trailing dot.
        while let first = s.first, first.isNumber {
            while let c = s.first, c.isNumber { s = s.dropFirst() }
            guard s.first == "." else { break }
            let afterDot = s.dropFirst()
            s = afterDot
            if afterDot.first?.isNumber != true { break }   // trailing dot ends the number
        }
        // An optional single terminator for non-dotted styles like "2:" or "1)".
        if s.first == ":" || s.first == ")" { s = s.dropFirst() }
        // Require whitespace after the number, so "1stPlace" is not treated as numbered.
        guard let c = s.first, c == " " || c == "\t" else { return text }
        while let c = s.first, c == " " || c == "\t" { s = s.dropFirst() }
        return String(s)
    }

    // The highest (most prominent, lowest-numbered) heading level present, and how many headings share it.
    private func topLevel(of headings: [MergedHeading]) -> (level: Int, count: Int)? {
        guard let level = headings.map(\.level).min() else { return nil }
        return (level, headings.filter { $0.level == level }.count)
    }

    private func topLevelDescription(_ top: (level: Int, count: Int)) -> String {
        let level = "Highest: H\(top.level)"
        return top.count > 1 ? "\(level) · \(top.count) at this level" : level
    }

    // MARK: - Heading extraction

    private func rebuild() {
        var map: [URL: [MergedHeading]] = [:]
        for url in session.selected {
            map[url] = Self.headings(in: store.readBody(url: url) ?? "")
        }
        blobHeadings = map
    }

    // Extracts ATX headings (`#`…`######`) in document order, skipping fenced code blocks so a `#`
    // inside a code sample is not mistaken for a heading.
    static func headings(in markdown: String) -> [MergedHeading] {
        var out: [MergedHeading] = []
        var fence: Character? = nil   // the open fence's character (` or ~), nil when not in a fence
        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let token = trimmed.first!
                if fence == nil { fence = token }
                else if fence == token { fence = nil }
                continue
            }
            if fence != nil { continue }
            if let heading = parseATX(rawLine) { out.append(heading) }
        }
        return out
    }

    // Parses one line as an ATX heading, or nil. Allows up to three leading spaces, requires a space
    // (or line end) after the `#` run, and strips any optional closing `#` sequence.
    private static func parseATX(_ line: String) -> MergedHeading? {
        var s = Substring(line)
        var leading = 0
        while s.first == " ", leading < 3 { s = s.dropFirst(); leading += 1 }

        var level = 0
        while s.first == "#" { level += 1; s = s.dropFirst() }
        guard (1...6).contains(level) else { return nil }
        guard s.isEmpty || s.first == " " || s.first == "\t" else { return nil }

        var text = s.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        text = strippingLeadingNumber(text.trimmingCharacters(in: .whitespaces))
        return MergedHeading(level: level, text: text)
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
                .foregroundColor(appColors.textResting)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                stepButton("minus", enabled: value > range.lowerBound) {
                    if value > range.lowerBound { value -= 1 }
                }
                Text(format(value))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(appColors.textBody)
                    .frame(minWidth: 26)
                stepButton("plus", enabled: value < range.upperBound) {
                    if value < range.upperBound { value += 1 }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(appColors.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(appColors.borderCard, lineWidth: 1))
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(enabled ? appColors.textResting : appColors.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// A labeled switch styled to the accent color.
private struct ToggleRow: View {
    @EnvironmentObject var appColors: AppColors
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(appColors.textResting)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(appColors.metaIndication)
    }
}

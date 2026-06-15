import SwiftUI

// A heading pulled from a selected blob, in merge order.
struct MergedHeading: Identifiable {
    let id = UUID()
    let level: Int     // 1...6, the number of leading `#`
    let text: String   // heading text, marks stripped
}

// The second MB stage. Left pane (`chromePanel`): heading adjustment controls (deferred). Right pane
// (`surface`): a live preview of every heading that the merge will include, in selection order,
// rendered natively but styled roughly like the editor — the editor font, bold, `textHeading`, with
// the literal `#` marks kept and all levels at the same size (the editor's own behavior).
struct MergeHeadingsStage: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @ObservedObject var session: MergeSession

    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"

    @State private var headings: [MergedHeading] = []

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

    // MARK: - Left pane: adjustments (deferred)

    private var adjustmentsPane: some View {
        VStack {
            Spacer()
            Text("Heading adjustments will go here.")
                .font(.system(size: 12))
                .foregroundColor(appColors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right pane: heading preview

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: headingSize * 0.8) {
                if headings.isEmpty {
                    Text("No headings found in the selected blobs.")
                        .font(.system(size: 13))
                        .foregroundColor(appColors.textMuted)
                } else {
                    ForEach(headings) { heading in
                        Text(markdownLine(for: heading))
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

    // MARK: - Heading extraction

    // Rebuilds the preview from the current selection. Recomputed on appear; the selection is fixed
    // while this stage is shown.
    private func rebuild() {
        var result: [MergedHeading] = []
        for url in session.selected {
            guard let body = store.readBody(url: url) else { continue }
            result.append(contentsOf: Self.headings(in: body))
        }
        headings = result
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
        return MergedHeading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }
}

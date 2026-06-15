import Foundation

// A heading in the merged document: its `#` level and the text that follows. Text is always stored
// number-free; a merge number is reapplied only when renumbering is on.
struct MergedHeading: Identifiable {
    let id = UUID()
    let level: Int     // 1...6, the number of leading `#`
    let text: String   // heading text, marks and any manual number stripped
}

// Produces the merged document from a `MergeSession`. It concatenates the selected blobs' bodies in
// order and rewrites their headings according to the session's adjustments: per-blob and merge-wide
// demotion, stripping of any manual numbers, and continuous nested renumbering across the whole result.
//
// The same routine yields both the file body that gets written and the heading list the preview shows,
// so the two can never drift. Callers supply a `body` closure so the source can be either cached text
// (the preview) or a fresh disk read (finalizing).
enum MergeEngine {

    // `body` is the full markdown to write (no front matter); `headings` is every heading in final
    // form, in order, for the preview.
    static func merge(session: MergeSession, body: (URL) -> String?) -> (body: String, headings: [MergedHeading]) {
        let wide = session.headingConfig

        // Pass 1 — per blob: optionally prepend a synthesized heading, then level-adjust and clean every
        // heading line. Non-heading lines and fenced-code lines are kept verbatim.
        var segments: [String] = []
        for url in session.selected {
            let cfg = session.blobConfig(for: url)
            let raw = body(url) ?? ""
            let adjust = cfg.adjustBy + wide.adjustAllBy

            var lines = raw.components(separatedBy: "\n")
            // A blob with no headings of its own contributes the user's synthesized heading, inserted at
            // its chosen level so the adjustment pass below treats it like any other heading.
            let added = strippingLeadingNumber(cfg.addedHeadingText.trimmingCharacters(in: .whitespaces))
            if cfg.addHeading, !added.isEmpty, headings(in: raw).isEmpty {
                lines.insert(String(repeating: "#", count: cfg.addedHeadingLevel) + " " + added, at: 0)
            }

            var out: [String] = []
            var fence: Character? = nil
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let token = trimmed.first!
                    if fence == nil { fence = token } else if fence == token { fence = nil }
                    out.append(line); continue
                }
                if fence != nil { out.append(line); continue }
                if let h = parseATX(line) {
                    // Positive promotes (toward H1), negative demotes (toward H6), so a higher number means
                    // a more prominent heading.
                    let level = max(1, min(6, h.level - adjust))
                    out.append(String(repeating: "#", count: level) + " " + h.text)
                } else {
                    out.append(line)
                }
            }
            // Trim blank edges so the blobs join with exactly one blank line between them.
            while out.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeFirst() }
            while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
            if !out.isEmpty { segments.append(out.joined(separator: "\n")) }
        }

        // Footnotes: each blob numbers its own references independently, so the same `[^1]` can mean
        // different things across blobs. Renumber them into one continuous sequence (in order of first
        // reference across the whole merge) and gather every definition for the document's foot.
        let (proseSegments, footnoteDefs) = renumberFootnotes(segments)
        let merged = proseSegments.joined(separator: "\n\n")

        // Pass 2 — across the whole document: collect the final heading list and, when renumbering is on,
        // prepend nested numbers. Headings are already demoted and number-free from pass 1. Numbering
        // anchors at H1 when `numberH1` is set, otherwise at H2 (so the first number is "1." and H1s are
        // left unnumbered).
        let base = wide.numberH1 ? 1 : 2
        var counters: [Int] = []
        var fence: Character? = nil
        var finalLines: [String] = []
        var headingList: [MergedHeading] = []
        for line in merged.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let token = trimmed.first!
                if fence == nil { fence = token } else if fence == token { fence = nil }
                finalLines.append(line); continue
            }
            if fence != nil { finalLines.append(line); continue }
            guard let h = parseATX(line) else { finalLines.append(line); continue }

            if wide.renumber, h.level >= base {
                let number = nextNumber(&counters, depth: h.level - base)
                let text = number + " " + h.text
                finalLines.append(String(repeating: "#", count: h.level) + " " + text)
                headingList.append(MergedHeading(level: h.level, text: text))
            } else {
                finalLines.append(line)
                headingList.append(MergedHeading(level: h.level, text: h.text))
            }
        }

        var output = finalLines.joined(separator: "\n")
        if !footnoteDefs.isEmpty {
            output = output.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            output += "\n\n" + footnoteDefs.joined(separator: "\n") + "\n"
        }
        return (output, headingList)
    }

    // Advances the nested counters for a heading at numbering `depth` (0-based) and returns its number
    // (e.g. "1.", "1.1."). Deeper counters are dropped; skipped intermediate levels start at 1.
    private static func nextNumber(_ counters: inout [Int], depth: Int) -> String {
        if depth < counters.count {
            counters[depth] += 1
            counters.removeSubrange((depth + 1)..<counters.count)
        } else {
            while counters.count < depth { counters.append(1) }
            counters.append(1)
        }
        return counters.map(String.init).joined(separator: ".") + "."
    }

    // MARK: - Heading parsing

    // Extracts ATX headings (`#`…`######`) in document order, skipping fenced code blocks so a `#`
    // inside a code sample is not mistaken for a heading.
    static func headings(in markdown: String) -> [MergedHeading] {
        var out: [MergedHeading] = []
        var fence: Character? = nil   // the open fence's character (` or ~), nil when not in a fence
        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let token = trimmed.first!
                if fence == nil { fence = token } else if fence == token { fence = nil }
                continue
            }
            if fence != nil { continue }
            if let heading = parseATX(rawLine) { out.append(heading) }
        }
        return out
    }

    // Parses one line as an ATX heading, or nil. Allows up to three leading spaces, requires a space (or
    // line end) after the `#` run, strips any closing `#` sequence, and strips a leading manual number.
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

    // Strips a leading manual number from heading text — nested dotted forms ("1.", "1.1.", "2.3.1")
    // and simple terminated forms ("2:", "1)") — together with the whitespace after it, returning the
    // bare title. Headings are stored number-free so the level is the single source of truth; numbers
    // are reapplied only by the renumbering pass. Text without such a prefix is returned unchanged.
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

    // MARK: - Footnotes

    // A reference `[^label]` (not the start of a `[^x](link)`), a definition line `[^label]: text`, and a
    // continuation line (indented, then non-blank). These mirror the editor's "Arrange Footnotes" command.
    private static let footnoteRef = try! NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\](?!\\()")
    private static let footnoteDef = try! NSRegularExpression(pattern: "^\\[\\^([^\\]]+)\\]:[ \\t]?(.*)$")
    private static let footnoteContinuation = try! NSRegularExpression(pattern: "^[ \\t]+\\S")

    // Renumbers footnotes across the merged blobs so every reference is unique. Each blob's references
    // resolve only to that blob's own definitions; each newly seen reference then takes the next number in
    // document order. Returns the prose segments with references rewritten, and the formatted definition
    // blocks for the foot of the document (in number order, with any unreferenced definitions kept after).
    static func renumberFootnotes(_ segments: [String]) -> (segments: [String], definitions: [String]) {
        var counter = 0
        var definitions: [String] = []
        var outSegments: [String] = []

        for segment in segments {
            let lines = segment.components(separatedBy: "\n")
            let (order, defs, defLineIndices) = footnoteDefinitions(in: lines)
            let prose = lines.enumerated()
                .filter { !defLineIndices.contains($0.offset) }
                .map(\.element)
                .joined(separator: "\n")

            // Rewrite references in document order, numbering each defined label the first time it is seen.
            var assigned: [String: String] = [:]
            let ns = prose as NSString
            var rewritten = ""
            var cursor = 0
            footnoteRef.enumerateMatches(in: prose, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match = match else { return }
                let label = ns.substring(with: match.range(at: 1))
                rewritten += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if let defLines = defs[label] {
                    if assigned[label] == nil {
                        counter += 1
                        assigned[label] = String(counter)
                        definitions.append(formatFootnote(number: assigned[label]!, lines: defLines))
                    }
                    rewritten += "[^\(assigned[label]!)]"
                } else {
                    rewritten += ns.substring(with: match.range)   // reference with no definition: left as-is
                }
                cursor = match.range.location + match.range.length
            }
            rewritten += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))

            // Defined but never referenced: keep them, numbered, so nothing is silently dropped.
            for label in order where assigned[label] == nil {
                counter += 1
                definitions.append(formatFootnote(number: String(counter), lines: defs[label]!))
            }

            // Trim blank edges left behind by stripped definition lines; drop a segment that is now empty.
            var proseLines = rewritten.components(separatedBy: "\n")
            while proseLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { proseLines.removeFirst() }
            while proseLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { proseLines.removeLast() }
            if !proseLines.isEmpty { outSegments.append(proseLines.joined(separator: "\n")) }
        }
        return (outSegments, definitions)
    }

    // Collects footnote definitions from a blob's lines: the label order (first occurrence), each label's
    // text lines (the first line plus de-indented continuations), and the indices of every line belonging
    // to a definition, so the caller can strip them from the prose.
    private static func footnoteDefinitions(in lines: [String]) -> (order: [String], defs: [String: [String]], lineIndices: Set<Int>) {
        var order: [String] = []
        var defs: [String: [String]] = [:]
        var indices: Set<Int> = []

        var i = 0
        while i < lines.count {
            let ns = lines[i] as NSString
            guard let match = footnoteDef.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) else {
                i += 1; continue
            }
            let label = ns.substring(with: match.range(at: 1))
            var text = [ns.substring(with: match.range(at: 2))]
            indices.insert(i)

            var j = i + 1
            while j < lines.count, isFootnoteContinuation(lines[j]) {
                text.append(stripLeadingWhitespace(lines[j]))
                indices.insert(j)
                j += 1
            }
            if defs[label] == nil { order.append(label) }
            defs[label] = text          // a repeated label keeps its last definition, as the editor does
            i = j
        }
        return (order, defs, indices)
    }

    // A definition block: "[^n]: first line" (trailing whitespace trimmed) with continuations re-indented
    // four spaces.
    private static func formatFootnote(number: String, lines: [String]) -> String {
        let first = "[^\(number)]: \(lines[0])".replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        let rest = lines.dropFirst().map { "    " + $0 }
        return ([first] + rest).joined(separator: "\n")
    }

    private static func isFootnoteContinuation(_ line: String) -> Bool {
        let ns = line as NSString
        return footnoteContinuation.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func stripLeadingWhitespace(_ line: String) -> String {
        var s = Substring(line)
        while let c = s.first, c == " " || c == "\t" { s = s.dropFirst() }
        return String(s)
    }
}

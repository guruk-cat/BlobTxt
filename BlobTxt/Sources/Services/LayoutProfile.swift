import Foundation

// A single profile. The set of overrides that shape a Print/PDF export.
// Every styling field is optional. A nil value means "emit no CSS for this and let pandoc + weasyprint decide" (the vanilla default). Figure-caption numbering is always applied and is therefore not a stored field.
struct LayoutProfile: Codable, Equatable, Identifiable {
    // The built-in default profile's fixed identity, so a go-to reference to it survives app launches even though the default itself is synthesized in code rather than persisted.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-0000000DEFA0")!

    var id: UUID = UUID()
    var name: String = "Untitled Profile"

    // Body text styling.
    var bodyFontFamily: String?
    var bodyFontSizePt: Double?
    var bodyAlignment: TextAlignment?
    var hyphenation: Bool = false

    // Page geometry.
    var paperSize: PaperSize?
    var orientation: Orientation?
    var marginTopIn: Double?
    var marginBottomIn: Double?
    var marginSideIn: Double?
    var pageNumbers: Bool = false

    var isDefault: Bool { id == LayoutProfile.defaultID }

    // The built-in baseline: all overrides unset, so output is plain pandoc + weasyprint (plus the always-on figure numbering).
    static var defaultProfile: LayoutProfile {
        LayoutProfile(id: defaultID, name: "Default")
    }

    enum TextAlignment: String, Codable, CaseIterable {
        case left, right, justified, center
        var cssValue: String { self == .justified ? "justify" : rawValue }
        var label: String { rawValue.capitalized }
    }

    enum PaperSize: String, Codable, CaseIterable {
        case letter, legal, a4, a5
        var cssValue: String {
            switch self {
            case .letter: return "letter"
            case .legal:  return "legal"
            case .a4:     return "A4"
            case .a5:     return "A5"
            }
        }
        var label: String {
            switch self {
            case .letter: return "Letter"
            case .legal:  return "Legal"
            case .a4:     return "A4"
            case .a5:     return "A5"
            }
        }
    }

    enum Orientation: String, Codable, CaseIterable {
        case portrait, landscape
        var cssValue: String { rawValue }
        var label: String { rawValue.capitalized }
    }
}

// MARK: - CSS generation

extension LayoutProfile {
    // Always-on: pandoc promotes a standalone image's alt-text into a <figcaption>; this numbers them.
    private static let figureNumberingCSS = """
    body { counter-reset: figure; }
    figure { break-inside: avoid; }
    figcaption::before {
      counter-increment: figure;
      content: "Figure " counter(figure) ". ";
      font-weight: bold;
    }
    """

    // The full <style> block pandoc injects into the HTML <head>, combining this profile's overrides with the always-on figure numbering.
    func headerHTML() -> String {
        var css = ""

        // @page: paper size, orientation, margins, and page numbers.
        var pageProps: [String] = []
        switch (paperSize, orientation) {
        case let (size?, orient?): pageProps.append("size: \(size.cssValue) \(orient.cssValue);")
        case let (size?, nil):     pageProps.append("size: \(size.cssValue);")
        case let (nil, orient?):   pageProps.append("size: \(orient.cssValue);")
        case (nil, nil):           break
        }
        if let t = marginTopIn    { pageProps.append("margin-top: \(trim(t))in;") }
        if let b = marginBottomIn { pageProps.append("margin-bottom: \(trim(b))in;") }
        if let s = marginSideIn   { pageProps.append("margin-left: \(trim(s))in; margin-right: \(trim(s))in;") }
        let pageNumberBox = pageNumbers ? " @bottom-center { content: counter(page); }" : ""
        if !pageProps.isEmpty || !pageNumberBox.isEmpty {
            css += "@page { \(pageProps.joined(separator: " "))\(pageNumberBox) }\n"
        }

        // body: font, size, alignment, hyphenation.
        var bodyProps: [String] = []
        if let f = bodyFontFamily { bodyProps.append("font-family: \"\(f)\";") }
        if let s = bodyFontSizePt { bodyProps.append("font-size: \(trim(s))pt;") }
        if let a = bodyAlignment  { bodyProps.append("text-align: \(a.cssValue);") }
        if hyphenation            { bodyProps.append("hyphens: auto;") }
        if !bodyProps.isEmpty {
            css += "body { \(bodyProps.joined(separator: " ")) }\n"
        }

        css += LayoutProfile.figureNumberingCSS
        return "<style>\n\(css)\n</style>"
    }

    // Drops a trailing ".0" so whole numbers render as "1in" rather than "1.0in".
    private func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
